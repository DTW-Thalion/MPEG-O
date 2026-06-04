/*
 * TestFormatReaders — OT5: per-format TTIOReader adapter classes.
 *
 * Verifies the 11 per-format adapters that normalize each importer into a
 * TTIOImportedDataset draft (mirroring the merged Java
 * importers.readers.*Adapter classes + the Python readers behavior):
 *
 *   (1) Each adapter, instantiated, conformsToProtocol:@protocol(TTIOReader).
 *   (2) A real mzML round-trip: build a tiny .tio with one MS run, export to
 *       mzML via TTIOMzMLWriter, run the MzML adapter -readInputs:options:
 *       progress:error: -> draft -> -writeToPath: -> reopen -> assert the MS
 *       run is present (write-through delegate path).
 *   (3) A real imzML round-trip (NEW ObjC capability): write a tiny
 *       continuous-mode imzML+ibd via TTIOImzMLWriter, run the ImzML adapter
 *       -> draft with a non-nil msImage + write-through delegate -> -writeToPath:
 *       -> reopen the image via +[TTIOMSImage readFromFilePath:] and assert the
 *       cube dimensions match.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Import/TTIOReaderAdapters.h"
#import "Import/TTIOReader.h"
#import "Import/TTIOImportedDataset.h"

#import "Core/TTIOSignalArray.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Export/TTIOMzMLWriter.h"
#import "Export/TTIOImzMLWriter.h"
#import "Import/TTIOImzMLReader.h"
#import "Image/TTIOMSImage.h"

static NSString *ofrTmp(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_ot5_%d_%@",
            (int)getpid(), suffix];
}

static TTIOSpectralDataset *ofrBuildMsDataset(void)
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
    return [[TTIOSpectralDataset alloc] initWithTitle:@"ot5"
                                   isaInvestigationId:@""
                                               msRuns:@{@"run_0001": run}
                                              nmrRuns:@{}
                                      identifications:@[]
                                      quantifications:@[]
                                    provenanceRecords:@[]
                                          transitions:nil];
}

void testFormatReaders(void)
{
    @autoreleasepool {
        // (1) Conformance: each of the 11 adapter classes, instantiated,
        //     conforms to TTIOReader.
        NSArray<Class> *classes = @[
            [TTIOMzMLReaderAdapter class],
            [TTIOMzTabReaderAdapter class],
            [TTIOImzMLReaderAdapter class],
            [TTIONmrMLReaderAdapter class],
            [TTIOThermoRawReaderAdapter class],
            [TTIOWatersMassLynxReaderAdapter class],
            [TTIOJcampDxReaderAdapter class],
            [TTIOBrukerReaderAdapter class],
            [TTIOBamReaderAdapter class],
            [TTIOSamReaderAdapter class],
            [TTIOCramReaderAdapter class],
        ];
        NSUInteger conformCount = 0;
        for (Class cls in classes) {
            id<TTIOReader> adapter = [[cls alloc] init];
            if ([adapter conformsToProtocol:@protocol(TTIOReader)]) conformCount++;
        }
        PASS(conformCount == classes.count,
             "OT5: all 11 per-format adapters conform to TTIOReader");

        // (2) mzML round-trip via the MzML adapter (write-through delegate).
        TTIOSpectralDataset *src = ofrBuildMsDataset();
        NSString *mzmlPath = ofrTmp(@"src.mzML");
        unlink(mzmlPath.fileSystemRepresentation);
        NSError *err = nil;
        BOOL wrote = [TTIOMzMLWriter writeDataset:src toPath:mzmlPath
                                  zlibCompression:NO error:&err];
        PASS(wrote, "OT5: built mzML fixture via TTIOMzMLWriter");

        TTIOMzMLReaderAdapter *mzAdapter = [[TTIOMzMLReaderAdapter alloc] init];
        err = nil;
        TTIOImportedDataset *mzDraft =
            [mzAdapter readInputs:@[mzmlPath] options:@{} progress:nil error:&err];
        PASS([mzDraft isKindOfClass:[TTIOImportedDataset class]],
             "OT5: MzML adapter returns a TTIOImportedDataset draft");
        PASS(mzDraft.writeDelegate != nil,
             "OT5: MzML draft carries a write-through delegate");

        NSString *mzTio = ofrTmp(@"mzml_out.tio");
        unlink(mzTio.fileSystemRepresentation);
        err = nil;
        BOOL mzOk = [mzDraft writeToPath:mzTio error:&err];
        PASS(mzOk, "OT5: MzML draft -writeToPath: writes a .tio");

        TTIOSpectralDataset *mzReopened =
            [TTIOSpectralDataset readFromFilePath:mzTio error:&err];
        PASS(mzReopened != nil, "OT5: reopened mzML-imported .tio");
        PASS(mzReopened.msRuns.count >= 1,
             "OT5: mzML-imported .tio has at least one MS run");
        [mzReopened closeFile];
        unlink(mzmlPath.fileSystemRepresentation);
        unlink(mzTio.fileSystemRepresentation);

        // (3) imzML round-trip via the ImzML adapter (NEW: produces an image .tio).
        NSString *imzmlPath = ofrTmp(@"img.imzML");
        NSString *ibdPath =
            [[imzmlPath stringByDeletingPathExtension]
                stringByAppendingPathExtension:@"ibd"];
        unlink(imzmlPath.fileSystemRepresentation);
        unlink(ibdPath.fileSystemRepresentation);

        double mz[16];
        for (int i = 0; i < 16; i++) mz[i] = 100.0 + i * 10.0;
        NSData *mzData = [NSData dataWithBytes:mz length:16 * sizeof(double)];
        NSMutableArray *pixels = [NSMutableArray array];
        // 2x2 grid, 1-indexed pixels.
        for (NSInteger y = 1; y <= 2; y++) {
            for (NSInteger x = 1; x <= 2; x++) {
                double in[16];
                for (int i = 0; i < 16; i++) in[i] = (double)((y * 2 + x) * 100 + i);
                NSData *inData = [NSData dataWithBytes:in length:16 * sizeof(double)];
                NSError *pe = nil;
                TTIOImzMLPixelSpectrum *p =
                    [[TTIOImzMLPixelSpectrum alloc] initWithX:x y:y z:1
                                                      mzArray:mzData
                                               intensityArray:inData
                                                        error:&pe];
                [pixels addObject:p];
            }
        }
        err = nil;
        TTIOImzMLWriteResult *wres = [TTIOImzMLWriter
            writePixels:pixels toImzMLPath:imzmlPath ibdPath:nil
                   mode:@"continuous"
               gridMaxX:2 gridMaxY:2 gridMaxZ:1
             pixelSizeX:25.0 pixelSizeY:25.0
            scanPattern:@"flyback" uuidHex:nil error:&err];
        PASS(wres != nil, "OT5: built continuous-mode imzML fixture");

        TTIOImzMLReaderAdapter *imzAdapter = [[TTIOImzMLReaderAdapter alloc] init];
        err = nil;
        TTIOImportedDataset *imzDraft =
            [imzAdapter readInputs:@[imzmlPath] options:@{} progress:nil error:&err];
        PASS([imzDraft isKindOfClass:[TTIOImportedDataset class]],
             "OT5: ImzML adapter returns a TTIOImportedDataset draft");
        PASS(imzDraft.msImage != nil,
             "OT5: ImzML draft carries a non-nil msImage (NEW capability)");
        PASS(imzDraft.writeDelegate != nil,
             "OT5: ImzML draft carries an image write-through delegate");
        if (imzDraft.msImage) {
            PASS(imzDraft.msImage.width == 2 && imzDraft.msImage.height == 2,
                 "OT5: ImzML image cube is 2x2");
            PASS(imzDraft.msImage.spectralPoints == 16,
                 "OT5: ImzML image has 16 spectral points");
        }

        NSString *imzTio = ofrTmp(@"imzml_out.tio");
        unlink(imzTio.fileSystemRepresentation);
        err = nil;
        BOOL imzOk = [imzDraft writeToPath:imzTio error:&err];
        PASS(imzOk, "OT5: ImzML draft -writeToPath: writes an image .tio");

        TTIOMSImage *reopenedImg =
            [TTIOMSImage readFromFilePath:imzTio error:&err];
        PASS(reopenedImg != nil, "OT5: reopened imzML-imported image .tio");
        PASS(reopenedImg.width == 2 && reopenedImg.height == 2,
             "OT5: reopened image cube is 2x2");
        PASS(reopenedImg.spectralPoints == 16,
             "OT5: reopened image has 16 spectral points");

        unlink(imzmlPath.fileSystemRepresentation);
        unlink(ibdPath.fileSystemRepresentation);
        unlink(imzTio.fileSystemRepresentation);
    }
}
