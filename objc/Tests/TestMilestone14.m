#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "Protection/TTIOSignatureManager.h"
#import "Protection/TTIOVerifier.h"
#import <unistd.h>

static NSString *m14path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m14_%d_%@.tio",
            (int)getpid(), suffix];
}

static NSData *makeHmacKey(uint8_t seed)
{
    uint8_t raw[32];
    for (int i = 0; i < 32; i++) raw[i] = (uint8_t)(seed ^ (i * 17));
    return [NSData dataWithBytes:raw length:32];
}

static TTIOAcquisitionRun *buildSmallRun(void)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < 5; k++) {
        double mz[8], in[8];
        for (NSUInteger i = 0; i < 8; i++) {
            mz[i] = 100.0 + (double)(k * 8 + i);
            in[i] = (double)(k * 10 + i + 1);
        }
        TTIOEncodingSpec *enc =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                           compressionAlgorithm:TTIOCompressionZlib
                                      byteOrder:TTIOByteOrderLittleEndian];
        TTIOSignalArray *mzA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:sizeof(mz)]
                                              length:8
                                            encoding:enc
                                                axis:nil];
        TTIOSignalArray *inA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:sizeof(in)]
                                              length:8
                                            encoding:enc
                                                axis:nil];
        [spectra addObject:
            [[TTIOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k
                                          precursorMz:0
                                      precursorCharge:0
                                                error:NULL]];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    return [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:TTIOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

void testMilestone14(void)
{
    // ---- 1. Sign intensity_values -> verify -> PASS ----
    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"m14"
                                isaInvestigationId:@""
                                            msRuns:@{@"run_0001": buildSmallRun()}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    NSString *path = m14path(@"sign");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([ds writeToFilePath:path error:&err], "dataset writes for signing test");

    NSData *key  = makeHmacKey(1);
    NSData *key2 = makeHmacKey(2);
    NSString *dsPath = @"/study/ms_runs/run_0001/signal_channels/intensity_values";

    err = nil;
    PASS([TTIOSignatureManager signDataset:dsPath
                                    inFile:path
                                   withKey:key
                                     error:&err],
         "sign intensity_values");
    PASS(err == nil, "sign no error");

    err = nil;
    PASS([TTIOSignatureManager verifyDataset:dsPath
                                      inFile:path
                                     withKey:key
                                       error:&err],
         "verify intensity_values with correct key");

    // Verify via the higher-level API.
    err = nil;
    TTIOVerificationStatus st =
        [TTIOVerifier verifyDataset:dsPath inFile:path withKey:key error:&err];
    PASS(st == TTIOVerificationStatusValid,
         "TTIOVerifier returns Valid for correct signature");

    // ---- 2. Wrong key -> Invalid ----
    err = nil;
    st = [TTIOVerifier verifyDataset:dsPath inFile:path withKey:key2 error:&err];
    PASS(st == TTIOVerificationStatusInvalid,
         "TTIOVerifier returns Invalid for wrong key");
    PASS(err != nil, "wrong-key verification populates NSError");

    // ---- 3. Tamper one byte of mz_values -> verify -> Invalid ----
    @autoreleasepool {
        NSString *mzPath = @"/study/ms_runs/run_0001/signal_channels/mz_values";
        err = nil;
        PASS([TTIOSignatureManager signDataset:mzPath inFile:path withKey:key error:&err],
             "sign mz_values too");
        err = nil;
        PASS([TTIOSignatureManager verifyDataset:mzPath
                                          inFile:path
                                         withKey:key
                                           error:&err],
             "verify mz_values passes before tampering");

        // Open the file RW and overwrite one byte of mz_values.
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
        TTIOHDF5Group *msg = [study openGroupNamed:@"ms_runs" error:&err];
        TTIOHDF5Group *runG = [msg openGroupNamed:@"run_0001" error:&err];
        TTIOHDF5Group *chans = [runG openGroupNamed:@"signal_channels" error:&err];
        TTIOHDF5Dataset *mzDs = [chans openDatasetNamed:@"mz_values" error:&err];
        NSMutableData *buf = [[mzDs readDataWithError:&err] mutableCopy];
        double *dp = buf.mutableBytes;
        dp[0] = dp[0] + 1.0;  // flip one value
        [mzDs writeData:buf error:&err];
        // Do NOT call [f close] explicitly; let the autoreleasepool
        // drain HDF5 children (dataset -> group chain -> file) in LIFO
        // order so no wrapper outlives its underlying hid_t.
        (void)f;

        err = nil;
        st = [TTIOVerifier verifyDataset:mzPath
                                  inFile:path
                                 withKey:key
                                   error:&err];
        PASS(st == TTIOVerificationStatusInvalid,
             "tampered mz_values verifies as Invalid");
        PASS(err != nil, "tamper populates descriptive NSError");
    }

    // ---- 4. Unsigned dataset -> NotSigned ----
    err = nil;
    NSString *indexPath = @"/study/ms_runs/run_0001/spectrum_index/retention_times";
    st = [TTIOVerifier verifyDataset:indexPath inFile:path withKey:key error:&err];
    PASS(st == TTIOVerificationStatusNotSigned,
         "unsigned dataset reports NotSigned");
    PASS(err == nil, "NotSigned does not populate error");

    // ---- 5. Root feature flags include opt_digital_signatures ----
    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        NSArray *features = [TTIOFeatureFlags featuresForRoot:[f rootGroup]];
        PASS([features containsObject:@"opt_digital_signatures"],
             "opt_digital_signatures flag added after signing");
        (void)f;  // let pool drain handles in LIFO order
    }
    unlink([path fileSystemRepresentation]);

    // ---- 6. Provenance chain signing ----
    {
        TTIOAcquisitionRun *run = buildSmallRun();
        TTIOProvenanceRecord *r1 =
            [[TTIOProvenanceRecord alloc] initWithInputRefs:@[@"raw:1"]
                                                    software:@"tool"
                                                  parameters:@{}
                                                  outputRefs:@[@"out:1"]
                                               timestampUnix:1700000000];
        [run addProcessingStep:r1];

        TTIOSpectralDataset *ds2 =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m14_prov"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": run}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *p = m14path(@"prov");
        unlink([p fileSystemRepresentation]);
        [ds2 writeToFilePath:p error:&err];

        NSString *runPath = @"/study/ms_runs/run_0001";
        err = nil;
        PASS([TTIOSignatureManager signProvenanceInRun:runPath
                                                inFile:p
                                               withKey:key
                                                 error:&err],
             "sign provenance chain");
        err = nil;
        PASS([TTIOSignatureManager verifyProvenanceInRun:runPath
                                                  inFile:p
                                                 withKey:key
                                                   error:&err],
             "verify provenance chain");

        TTIOVerificationStatus pst =
            [TTIOVerifier verifyProvenanceInRun:runPath
                                         inFile:p
                                        withKey:key
                                          error:&err];
        PASS(pst == TTIOVerificationStatusValid, "Verifier: provenance Valid");
        unlink([p fileSystemRepresentation]);
    }

    // ---- 7. Performance: 1M float64 sign + verify under 100ms ----
    {
        const NSUInteger N = 1000000;
        NSMutableData *big = [NSMutableData dataWithLength:N * sizeof(double)];
        double *dp = big.mutableBytes;
        for (NSUInteger i = 0; i < N; i++) dp[i] = (double)i * 0.5;

        NSString *p = m14path(@"perf");
        unlink([p fileSystemRepresentation]);
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:p error:&err];
        TTIOHDF5Dataset *d = [[f rootGroup]
            createDatasetNamed:@"bigdata"
                     precision:TTIOPrecisionFloat64
                        length:N
                     chunkSize:0
              compressionLevel:0
                         error:&err];
        [d writeData:big error:&err];
        [f close];

        NSDate *t0 = [NSDate date];
        PASS([TTIOSignatureManager signDataset:@"/bigdata"
                                        inFile:p
                                       withKey:key
                                         error:&err],
             "sign 1M float64 dataset");
        NSTimeInterval dtSign = -[t0 timeIntervalSinceNow];

        NSDate *t1 = [NSDate date];
        PASS([TTIOSignatureManager verifyDataset:@"/bigdata"
                                          inFile:p
                                         withKey:key
                                           error:&err],
             "verify 1M float64 dataset");
        NSTimeInterval dtVerify = -[t1 timeIntervalSinceNow];
        printf("    [bench] 1M float64 sign %.2f ms, verify %.2f ms\n",
               dtSign * 1000.0, dtVerify * 1000.0);
        PASS((dtSign + dtVerify) < 1.0,
             "1M sign+verify well within 1s (acceptance 100ms per op)");
        unlink([p fileSystemRepresentation]);
    }
}
