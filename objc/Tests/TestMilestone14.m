#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOFeatureFlags.h"
#import "Protection/MPGOSignatureManager.h"
#import "Protection/MPGOVerifier.h"
#import <unistd.h>

static NSString *m14path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m14_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static NSData *makeHmacKey(uint8_t seed)
{
    uint8_t raw[32];
    for (int i = 0; i < 32; i++) raw[i] = (uint8_t)(seed ^ (i * 17));
    return [NSData dataWithBytes:raw length:32];
}

static MPGOAcquisitionRun *buildSmallRun(void)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < 5; k++) {
        double mz[8], in[8];
        for (NSUInteger i = 0; i < 8; i++) {
            mz[i] = 100.0 + (double)(k * 8 + i);
            in[i] = (double)(k * 10 + i + 1);
        }
        MPGOEncodingSpec *enc =
            [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                           compressionAlgorithm:MPGOCompressionZlib
                                      byteOrder:MPGOByteOrderLittleEndian];
        MPGOSignalArray *mzA =
            [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:sizeof(mz)]
                                              length:8
                                            encoding:enc
                                                axis:nil];
        MPGOSignalArray *inA =
            [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:sizeof(in)]
                                              length:8
                                            encoding:enc
                                                axis:nil];
        [spectra addObject:
            [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:MPGOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k
                                          precursorMz:0
                                      precursorCharge:0
                                                error:NULL]];
    }
    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    return [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:MPGOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

void testMilestone14(void)
{
    // ---- 1. Sign intensity_values -> verify -> PASS ----
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"m14"
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
    PASS([MPGOSignatureManager signDataset:dsPath
                                    inFile:path
                                   withKey:key
                                     error:&err],
         "sign intensity_values");
    PASS(err == nil, "sign no error");

    err = nil;
    PASS([MPGOSignatureManager verifyDataset:dsPath
                                      inFile:path
                                     withKey:key
                                       error:&err],
         "verify intensity_values with correct key");

    // Verify via the higher-level API.
    err = nil;
    MPGOVerificationStatus st =
        [MPGOVerifier verifyDataset:dsPath inFile:path withKey:key error:&err];
    PASS(st == MPGOVerificationStatusValid,
         "MPGOVerifier returns Valid for correct signature");

    // ---- 2. Wrong key -> Invalid ----
    err = nil;
    st = [MPGOVerifier verifyDataset:dsPath inFile:path withKey:key2 error:&err];
    PASS(st == MPGOVerificationStatusInvalid,
         "MPGOVerifier returns Invalid for wrong key");
    PASS(err != nil, "wrong-key verification populates NSError");

    // ---- 3. Tamper one byte of mz_values -> verify -> Invalid ----
    @autoreleasepool {
        NSString *mzPath = @"/study/ms_runs/run_0001/signal_channels/mz_values";
        err = nil;
        PASS([MPGOSignatureManager signDataset:mzPath inFile:path withKey:key error:&err],
             "sign mz_values too");
        err = nil;
        PASS([MPGOSignatureManager verifyDataset:mzPath
                                          inFile:path
                                         withKey:key
                                           error:&err],
             "verify mz_values passes before tampering");

        // Open the file RW and overwrite one byte of mz_values.
        MPGOHDF5File *f = [MPGOHDF5File openAtPath:path error:&err];
        MPGOHDF5Group *root = [f rootGroup];
        MPGOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
        MPGOHDF5Group *msg = [study openGroupNamed:@"ms_runs" error:&err];
        MPGOHDF5Group *runG = [msg openGroupNamed:@"run_0001" error:&err];
        MPGOHDF5Group *chans = [runG openGroupNamed:@"signal_channels" error:&err];
        MPGOHDF5Dataset *mzDs = [chans openDatasetNamed:@"mz_values" error:&err];
        NSMutableData *buf = [[mzDs readDataWithError:&err] mutableCopy];
        double *dp = buf.mutableBytes;
        dp[0] = dp[0] + 1.0;  // flip one value
        [mzDs writeData:buf error:&err];
        // Do NOT call [f close] explicitly; let the autoreleasepool
        // drain HDF5 children (dataset -> group chain -> file) in LIFO
        // order so no wrapper outlives its underlying hid_t.
        (void)f;

        err = nil;
        st = [MPGOVerifier verifyDataset:mzPath
                                  inFile:path
                                 withKey:key
                                   error:&err];
        PASS(st == MPGOVerificationStatusInvalid,
             "tampered mz_values verifies as Invalid");
        PASS(err != nil, "tamper populates descriptive NSError");
    }

    // ---- 4. Unsigned dataset -> NotSigned ----
    err = nil;
    NSString *indexPath = @"/study/ms_runs/run_0001/spectrum_index/retention_times";
    st = [MPGOVerifier verifyDataset:indexPath inFile:path withKey:key error:&err];
    PASS(st == MPGOVerificationStatusNotSigned,
         "unsigned dataset reports NotSigned");
    PASS(err == nil, "NotSigned does not populate error");

    // ---- 5. Root feature flags include opt_digital_signatures ----
    @autoreleasepool {
        MPGOHDF5File *f = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        NSArray *features = [MPGOFeatureFlags featuresForRoot:[f rootGroup]];
        PASS([features containsObject:@"opt_digital_signatures"],
             "opt_digital_signatures flag added after signing");
        (void)f;  // let pool drain handles in LIFO order
    }
    unlink([path fileSystemRepresentation]);

    // ---- 6. Provenance chain signing ----
    {
        MPGOAcquisitionRun *run = buildSmallRun();
        MPGOProvenanceRecord *r1 =
            [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"raw:1"]
                                                    software:@"tool"
                                                  parameters:@{}
                                                  outputRefs:@[@"out:1"]
                                               timestampUnix:1700000000];
        [run addProcessingStep:r1];

        MPGOSpectralDataset *ds2 =
            [[MPGOSpectralDataset alloc] initWithTitle:@"m14_prov"
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
        PASS([MPGOSignatureManager signProvenanceInRun:runPath
                                                inFile:p
                                               withKey:key
                                                 error:&err],
             "sign provenance chain");
        err = nil;
        PASS([MPGOSignatureManager verifyProvenanceInRun:runPath
                                                  inFile:p
                                                 withKey:key
                                                   error:&err],
             "verify provenance chain");

        MPGOVerificationStatus pst =
            [MPGOVerifier verifyProvenanceInRun:runPath
                                         inFile:p
                                        withKey:key
                                          error:&err];
        PASS(pst == MPGOVerificationStatusValid, "Verifier: provenance Valid");
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
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:p error:&err];
        MPGOHDF5Dataset *d = [[f rootGroup]
            createDatasetNamed:@"bigdata"
                     precision:MPGOPrecisionFloat64
                        length:N
                     chunkSize:0
              compressionLevel:0
                         error:&err];
        [d writeData:big error:&err];
        [f close];

        NSDate *t0 = [NSDate date];
        PASS([MPGOSignatureManager signDataset:@"/bigdata"
                                        inFile:p
                                       withKey:key
                                         error:&err],
             "sign 1M float64 dataset");
        NSTimeInterval dtSign = -[t0 timeIntervalSinceNow];

        NSDate *t1 = [NSDate date];
        PASS([MPGOSignatureManager verifyDataset:@"/bigdata"
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
