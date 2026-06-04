/*
 * TestImporterExporterRegistry.m — OT7: importer + exporter registries.
 *
 * Mirrors the Python ttio.importers.registry + ttio.exporters.registry
 * (the single source of truth for the formats `ttio encode` / `ttio export`
 * accept and how each maps to / from a `.tio`). Verifies, for each registry:
 *
 *   (1) registryKeys() == the canonical key set (11 import / 8 export).
 *   (2) normalizeFormat: applies the alias table (e.g. "thermo" -> "thermo-raw").
 *   (3) specForFormat: returns nil + an error for an unknown format.
 *   (4) supportedEncodeFormats / supportedExportFormats == keys ∪ {fasta,fastq}.
 *   (5) a real mzML encode round-trip (build mzML fixture -> encodeFormat:
 *       -> reopen -> assert an MS run) and a real mzML export from a built .tio.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Import/TTIOImporterRegistry.h"
#import "Export/TTIOExporterRegistry.h"

#import "Core/TTIOSignalArray.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Export/TTIOMzMLWriter.h"

static NSString *ierTmp(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_ot7_%d_%@",
            (int)getpid(), suffix];
}

static TTIOSpectralDataset *ierBuildMsDataset(void)
{
    NSUInteger nSpec = 2, nPts = 8;
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < nSpec; k++) {
        double mz[16], in[16];
        for (NSUInteger i = 0; i < nPts; i++) {
            mz[i] = 100.0 + (double)(k * nPts + i) * 0.5;
            in[i] = (double)(k + 1) * 10.0 + (double)i;
        }
        TTIOEncodingSpec *enc =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                           compressionAlgorithm:TTIOCompressionZlib
                                      byteOrder:TTIOByteOrderLittleEndian];
        TTIOSignalArray *mzA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:nPts * sizeof(double)]
                                              length:nPts encoding:enc axis:nil];
        TTIOSignalArray *inA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:nPts * sizeof(double)]
                                              length:nPts encoding:enc axis:nil];
        [spectra addObject:
            [[TTIOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.5
                                          precursorMz:0
                                      precursorCharge:0
                                                error:NULL]];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@"" model:@""
                                              serialNumber:@"" sourceType:@""
                                              analyzerType:@"" detectorType:@""];
    TTIOAcquisitionRun *run =
        [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                    acquisitionMode:TTIOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];
    return [[TTIOSpectralDataset alloc] initWithTitle:@"ot7"
                                   isaInvestigationId:@""
                                               msRuns:@{@"run_0001": run}
                                              nmrRuns:@{}
                                      identifications:@[]
                                      quantifications:@[]
                                    provenanceRecords:@[]
                                          transitions:nil];
}

void testImporterExporterRegistry(void)
{
    @autoreleasepool {
        // ---- IMPORT registry ----------------------------------------
        NSSet *importKeys = [NSSet setWithArray:[TTIOImporterRegistry registryKeys]];
        NSSet *expectedImport = [NSSet setWithArray:@[
            @"mzml", @"mztab", @"imzml", @"nmrml", @"jcamp-dx",
            @"bruker-timstof", @"waters-masslynx", @"thermo-raw",
            @"bam", @"sam", @"cram"]];
        PASS([importKeys isEqualToSet:expectedImport],
             "OT7: importer registryKeys == the 11 canonical keys");

        PASS([[TTIOImporterRegistry normalizeFormat:@"thermo"]
                isEqualToString:@"thermo-raw"],
             "OT7: importer normalizeFormat: alias thermo -> thermo-raw");
        PASS([[TTIOImporterRegistry normalizeFormat:@"  JCAMP "]
                isEqualToString:@"jcamp-dx"],
             "OT7: importer normalizeFormat: trims + lowercases + aliases");

        NSError *ie = nil;
        id ispec = [TTIOImporterRegistry specForFormat:@"ome" error:&ie];
        PASS(ispec == nil && ie != nil,
             "OT7: importer specForFormat: unknown -> nil + error");

        NSSet *encFmts = [NSSet setWithArray:[TTIOImporterRegistry supportedEncodeFormats]];
        NSMutableSet *expEnc = [NSMutableSet setWithSet:expectedImport];
        [expEnc addObjectsFromArray:@[@"fasta", @"fastq"]];
        PASS([encFmts isEqualToSet:expEnc],
             "OT7: supportedEncodeFormats == 11 keys ∪ {fasta,fastq}");

        // (5) mzML encode round-trip via the registry.
        TTIOSpectralDataset *src = ierBuildMsDataset();
        NSString *mzmlPath = ierTmp(@"src.mzML");
        unlink(mzmlPath.fileSystemRepresentation);
        NSError *err = nil;
        BOOL wrote = [TTIOMzMLWriter writeDataset:src toPath:mzmlPath
                                  zlibCompression:NO error:&err];
        PASS(wrote, "OT7: built mzML fixture for encode round-trip");

        NSString *encTio = ierTmp(@"enc_out.tio");
        unlink(encTio.fileSystemRepresentation);
        err = nil;
        BOOL encOk = [TTIOImporterRegistry encodeFormat:@"mzml"
                                                 inputs:@[mzmlPath]
                                                 output:encTio
                                                options:@{}
                                                  error:&err];
        PASS(encOk, "OT7: encodeFormat:@\"mzml\" succeeds (err=%s)",
             err.localizedDescription.UTF8String ?: "(none)");

        TTIOSpectralDataset *encReopened =
            [TTIOSpectralDataset readFromFilePath:encTio error:&err];
        PASS(encReopened != nil, "OT7: reopened encode output .tio");
        PASS(encReopened.msRuns.count >= 1,
             "OT7: encode output .tio has at least one MS run");
        [encReopened closeFile];
        unlink(mzmlPath.fileSystemRepresentation);
        unlink(encTio.fileSystemRepresentation);

        // ---- EXPORT registry ----------------------------------------
        NSSet *exportKeys = [NSSet setWithArray:[TTIOExporterRegistry registryKeys]];
        NSSet *expectedExport = [NSSet setWithArray:@[
            @"mzml", @"mztab", @"nmrml", @"imzml", @"jcamp-dx",
            @"isa", @"bam", @"cram"]];
        PASS([exportKeys isEqualToSet:expectedExport],
             "OT7: exporter registryKeys == the 8 canonical keys");

        PASS([[TTIOExporterRegistry normalizeFormat:@"ISA-Tab"]
                isEqualToString:@"isa"],
             "OT7: exporter normalizeFormat: alias isa-tab -> isa");
        PASS([[TTIOExporterRegistry normalizeFormat:@" JDX "]
                isEqualToString:@"jcamp-dx"],
             "OT7: exporter normalizeFormat: trims + lowercases + aliases");

        NSError *xe = nil;
        id xspec = [TTIOExporterRegistry specForFormat:@"ome" error:&xe];
        PASS(xspec == nil && xe != nil,
             "OT7: exporter specForFormat: unknown -> nil + error");

        NSSet *expFmts = [NSSet setWithArray:[TTIOExporterRegistry supportedExportFormats]];
        NSMutableSet *expExp = [NSMutableSet setWithSet:expectedExport];
        [expExp addObjectsFromArray:@[@"fasta", @"fastq"]];
        PASS([expFmts isEqualToSet:expExp],
             "OT7: supportedExportFormats == 8 keys ∪ {fasta,fastq}");

        // (5) mzML export from a built .tio via the registry.
        NSString *expTio = ierTmp(@"exp_src.tio");
        [[NSFileManager defaultManager] removeItemAtPath:expTio error:NULL];
        err = nil;
        TTIOSpectralDataset *expSrc = ierBuildMsDataset();
        BOOL srcWrote = [expSrc writeToFilePath:expTio error:&err];
        PASS(srcWrote, "OT7: built .tio fixture for export round-trip (err=%s)",
             err.localizedDescription.UTF8String ?: "(none)");

        NSString *mzmlOut = ierTmp(@"exp_out.mzML");
        unlink(mzmlOut.fileSystemRepresentation);
        err = nil;
        BOOL expOk = [TTIOExporterRegistry exportFormat:@"mzml"
                                                tioPath:expTio
                                                  layer:nil
                                                 output:mzmlOut
                                                options:@{}
                                                  error:&err];
        PASS(expOk, "OT7: exportFormat:@\"mzml\" succeeds (err=%s)",
             err.localizedDescription.UTF8String ?: "(none)");
        NSDictionary *outAttrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:mzmlOut error:NULL];
        PASS(outAttrs != nil && [outAttrs fileSize] > 0,
             "OT7: export mzML output exists and is non-empty");

        unlink(expTio.fileSystemRepresentation);
        unlink(mzmlOut.fileSystemRepresentation);
    }
}
