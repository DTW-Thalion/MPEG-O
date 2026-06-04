/*
 * TestEncodeExportCli.m — OT8: TtioEncode / TtioExport CLI tools.
 *
 * Mirrors the Python `ttio encode` / `ttio export` umbrella subcommands
 * (ttio.tools.workbench_cli.cmd_encode / cmd_export) as standalone ObjC
 * tool binaries. Each lives under objc/Tools/obj/. Test pattern: fork-exec
 * the binary via NSTask with various argv, capture stdout/stderr/exit-code,
 * assert exit codes mirror Python:
 *
 *   0  success
 *   2  importer/exporter failure or bad/missing args
 *   3  unsupported / CLI-delegated (fasta/fastq) format
 *
 * Surfaces exercised:
 *   (1) TtioEncode --format xyz ...  -> exit 3 (unsupported)
 *   (2) TtioEncode --list-formats    -> exit 0 + stdout lists formats
 *   (3) a real mzML encode: build a .tio, export it to mzML (in-test via
 *       the SDK), then TtioEncode --format mzml --input <mzml>
 *       --output <out.tio> -> exit 0 + output exists
 *   (4) TtioExport --list-formats     -> exit 0
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include <unistd.h>

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

static NSString *kEECToolsDir =
    @"/home/toddw/TTI-O/objc/Tools/obj";

/** Run a CLI binary with the given args. Returns the termination
 *  status, or -1 when the tool isn't built. Captures stdout into
 *  outBuf and stderr into errBuf. */
static int eecRunTool(NSString *toolName, NSArray<NSString *> *args,
                      NSMutableData **outBuf, NSMutableData **errBuf)
{
    NSString *path = [kEECToolsDir stringByAppendingPathComponent:toolName];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        return -1;  // tool not built
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = args ?: @[];
    task.environment = [NSProcessInfo processInfo].environment;

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    @try {
        [task launch];
    } @catch (NSException *exc) {
        NSLog(@"eecRunTool: launch failed for %@: %@", path, exc.reason);
        return -2;
    }
    [task waitUntilExit];
    if (outBuf) {
        *outBuf = [[outPipe fileHandleForReading]
                       readDataToEndOfFile].mutableCopy;
    }
    if (errBuf) {
        *errBuf = [[errPipe fileHandleForReading]
                       readDataToEndOfFile].mutableCopy;
    }
    return task.terminationStatus;
}

static BOOL eecToolMissing(NSString *toolName)
{
    NSString *path = [kEECToolsDir stringByAppendingPathComponent:toolName];
    return ![[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

static NSString *eecTmp(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_ot8_%d_%@",
            (int)getpid(), suffix];
}

static TTIOSpectralDataset *eecBuildMsDataset(void)
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
    return [[TTIOSpectralDataset alloc] initWithTitle:@"ot8"
                                   isaInvestigationId:@""
                                               msRuns:@{@"run_0001": run}
                                              nmrRuns:@{}
                                      identifications:@[]
                                      quantifications:@[]
                                    provenanceRecords:@[]
                                          transitions:nil];
}

void testEncodeExportCli(void)
{
    @autoreleasepool {
        if (eecToolMissing(@"TtioEncode")) {
            NSLog(@"OT8: TtioEncode not built; skipping");
            PASS(NO, "OT8: TtioEncode binary must be built");
            return;
        }

        // (1) unsupported --format -> exit 3.
        {
            NSString *fakeIn = eecTmp(@"fake.xyz");
            [[NSData data] writeToFile:fakeIn atomically:YES];
            NSString *out = eecTmp(@"unsupported_out.tio");
            NSMutableData *o = nil, *e = nil;
            int rc = eecRunTool(@"TtioEncode",
                                @[@"--format", @"xyz",
                                  @"--input", fakeIn,
                                  @"--output", out], &o, &e);
            PASS(rc == 3,
                 "OT8 #1: TtioEncode --format xyz exits 3 (unsupported) (got %d)", rc);
            unlink(fakeIn.fileSystemRepresentation);
            unlink(out.fileSystemRepresentation);
        }

        // (2) --list-formats -> exit 0 + stdout lists formats.
        {
            NSMutableData *o = nil, *e = nil;
            int rc = eecRunTool(@"TtioEncode", @[@"--list-formats"], &o, &e);
            PASS(rc == 0, "OT8 #2: TtioEncode --list-formats exits 0 (got %d)", rc);
            NSString *outStr = [[NSString alloc] initWithData:o
                                                     encoding:NSUTF8StringEncoding];
            PASS([outStr containsString:@"mzml"],
                 "OT8 #3: TtioEncode --list-formats lists 'mzml'");
        }

        // (3) real mzML encode round-trip.
        {
            TTIOSpectralDataset *src = eecBuildMsDataset();
            NSString *mzmlPath = eecTmp(@"src.mzML");
            unlink(mzmlPath.fileSystemRepresentation);
            NSError *err = nil;
            BOOL wrote = [TTIOMzMLWriter writeDataset:src toPath:mzmlPath
                                      zlibCompression:NO error:&err];
            PASS(wrote, "OT8 #4: built mzML fixture (err=%s)",
                 err.localizedDescription.UTF8String ?: "(none)");

            NSString *outTio = eecTmp(@"enc_out.tio");
            unlink(outTio.fileSystemRepresentation);
            NSMutableData *o = nil, *e = nil;
            int rc = eecRunTool(@"TtioEncode",
                                @[@"--format", @"mzml",
                                  @"--input", mzmlPath,
                                  @"--output", outTio], &o, &e);
            NSString *errStr = [[NSString alloc] initWithData:e
                                                     encoding:NSUTF8StringEncoding];
            PASS(rc == 0,
                 "OT8 #5: TtioEncode --format mzml exits 0 (got %d, stderr=%s)",
                 rc, errStr.UTF8String ?: "");
            PASS([[NSFileManager defaultManager] fileExistsAtPath:outTio],
                 "OT8 #6: TtioEncode produced output .tio");
            unlink(mzmlPath.fileSystemRepresentation);
            unlink(outTio.fileSystemRepresentation);
        }

        // (4) TtioExport --list-formats -> exit 0.
        if (!eecToolMissing(@"TtioExport")) {
            NSMutableData *o = nil, *e = nil;
            int rc = eecRunTool(@"TtioExport", @[@"--list-formats"], &o, &e);
            PASS(rc == 0, "OT8 #7: TtioExport --list-formats exits 0 (got %d)", rc);
            NSString *outStr = [[NSString alloc] initWithData:o
                                                     encoding:NSUTF8StringEncoding];
            PASS([outStr containsString:@"mzml"],
                 "OT8 #8: TtioExport --list-formats lists 'mzml'");
        } else {
            PASS(NO, "OT8 #7: TtioExport binary must be built");
        }
    }
}
