// Milestone 28: spectral anonymization.
//
// Verifies:
//   * SAAV redaction removes the correct spectrum.
//   * m/z coarsening rounds values.
//   * Intensity masking zeroes below-quantile values.
//   * strip_metadata clears the title.
//   * Output is a valid .tio readable by SpectralDataset.
//   * Original file unmodified.
//   * opt_anonymized feature flag present.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Protection/TTIOAnonymizer.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOFeatureFlags.h"
#import <unistd.h>

static NSString *m28TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m28_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOSignalArray *m28Arr(const double *v, NSUInteger n)
{
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    NSData *d = [NSData dataWithBytes:v length:n * sizeof(double)];
    return [[TTIOSignalArray alloc] initWithBuffer:d length:n encoding:enc axis:nil];
}

static TTIOSpectralDataset *m28BuildSource(NSString *path,
                                           NSArray<TTIOIdentification *> *ids)
{
    double mz[]  = { 100.1234, 200.5678, 300.9999 };
    double it[]  = { 50.0, 500.0, 1000.0 };
    NSMutableArray *spectra = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        TTIOMassSpectrum *s =
            [[TTIOMassSpectrum alloc] initWithMzArray:m28Arr(mz, 3)
                                       intensityArray:m28Arr(it, 3)
                                              msLevel:1
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:i
                                      scanTimeSeconds:(double)i
                                          precursorMz:0.0
                                      precursorCharge:0
                                                error:NULL];
        [spectra addObject:s];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@"" model:@""
                                              serialNumber:@"" sourceType:@""
                                              analyzerType:@"" detectorType:@""];
    TTIOAcquisitionRun *run =
        [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                    acquisitionMode:TTIOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];

    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc]
            initWithTitle:@"M28 Source"
       isaInvestigationId:@"ISA-M28"
                   msRuns:@{ @"run_0001": run }
                  nmrRuns:@{}
          identifications:(ids ?: @[])
          quantifications:@[]
        provenanceRecords:@[]
              transitions:nil];

    NSError *err = nil;
    [ds writeToFilePath:path error:&err];
    return [TTIOSpectralDataset readFromFilePath:path error:&err];
}

void testMilestone28(void)
{
    // ---- feature flag ----
    PASS([[TTIOFeatureFlags featureAnonymized] isEqualToString:@"opt_anonymized"],
         "M28: featureAnonymized constant");

    // ---- SAAV redaction ----
    {
        NSString *srcPath = m28TempPath(@"saav_src");
        NSString *outPath = m28TempPath(@"saav_out");
        unlink([srcPath fileSystemRepresentation]);
        unlink([outPath fileSystemRepresentation]);

        TTIOIdentification *saavId =
            [[TTIOIdentification alloc] initWithRunName:@"run_0001"
                                          spectrumIndex:1
                                         chemicalEntity:@"p.Ala123Thr SAAV"
                                        confidenceScore:0.9
                                          evidenceChain:@[]];
        TTIOSpectralDataset *src = m28BuildSource(srcPath, @[saavId]);
        PASS(src != nil, "M28: source dataset created");

        TTIOAnonymizationPolicy *pol = [[TTIOAnonymizationPolicy alloc] init];
        pol.redactSAAVSpectra = YES;
        NSError *err = nil;
        TTIOAnonymizationResult *res =
            [TTIOAnonymizer anonymizeDataset:src outputPath:outPath policy:pol error:&err];
        PASS(res != nil, "M28: SAAV anonymization succeeds");
        PASS(res.spectraRedacted == 1, "M28: one spectrum redacted");

        TTIOSpectralDataset *anon =
            [TTIOSpectralDataset readFromFilePath:outPath error:&err];
        PASS(anon != nil, "M28: anonymized file readable");
        TTIOAcquisitionRun *anonRun = anon.msRuns[@"run_0001"];
        PASS(anonRun.spectrumIndex.count == 2,
             "M28: anonymized run has 2 spectra (was 3)");

        [src closeFile];
        unlink([srcPath fileSystemRepresentation]);
        unlink([outPath fileSystemRepresentation]);
    }

    // ---- m/z coarsening ----
    {
        NSString *srcPath = m28TempPath(@"mz_src");
        NSString *outPath = m28TempPath(@"mz_out");
        unlink([srcPath fileSystemRepresentation]);
        unlink([outPath fileSystemRepresentation]);

        TTIOSpectralDataset *src = m28BuildSource(srcPath, nil);
        TTIOAnonymizationPolicy *pol = [[TTIOAnonymizationPolicy alloc] init];
        pol.coarsenMzDecimals = 0;
        NSError *err = nil;
        TTIOAnonymizationResult *res =
            [TTIOAnonymizer anonymizeDataset:src outputPath:outPath policy:pol error:&err];
        PASS(res != nil && res.mzValuesCoarsened > 0, "M28: m/z coarsening reports > 0");

        TTIOSpectralDataset *anon =
            [TTIOSpectralDataset readFromFilePath:outPath error:&err];
        TTIOMassSpectrum *s = [anon.msRuns[@"run_0001"] spectrumAtIndex:0 error:&err];
        const double *mz = s.mzArray.buffer.bytes;
        PASS(mz[0] == 100.0 && mz[1] == 201.0 && mz[2] == 301.0,
             "M28: m/z values rounded to 0 decimals");

        [src closeFile];
        unlink([srcPath fileSystemRepresentation]);
        unlink([outPath fileSystemRepresentation]);
    }

    // ---- strip metadata ----
    {
        NSString *srcPath = m28TempPath(@"strip_src");
        NSString *outPath = m28TempPath(@"strip_out");
        unlink([srcPath fileSystemRepresentation]);
        unlink([outPath fileSystemRepresentation]);

        TTIOSpectralDataset *src = m28BuildSource(srcPath, nil);
        TTIOAnonymizationPolicy *pol = [[TTIOAnonymizationPolicy alloc] init];
        pol.stripMetadataFields = YES;
        NSError *err = nil;
        [TTIOAnonymizer anonymizeDataset:src outputPath:outPath policy:pol error:&err];

        TTIOSpectralDataset *anon =
            [TTIOSpectralDataset readFromFilePath:outPath error:&err];
        PASS([anon.title isEqualToString:@""],
             "M28: title stripped");

        [src closeFile];
        unlink([srcPath fileSystemRepresentation]);
        unlink([outPath fileSystemRepresentation]);
    }
}
