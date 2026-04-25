/*
 * TestMilestone17 — compound per-run provenance.
 *
 * Covers the v0.3 migration from ``@provenance_json`` (string attribute)
 * to a compound HDF5 dataset at ``/study/ms_runs/<run>/provenance/steps``
 * using the same compound type as the dataset-level ``/study/provenance``.
 *
 * The writer emits both forms during the transition so that (a) the v0.2
 * signature manager, which operates on the JSON attribute, keeps working
 * and (b) v0.2 readers can still load the file. The reader prefers the
 * compound form when present and falls back to the JSON mirror otherwise.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOFeatureFlags.h"
#import <hdf5.h>
#import <unistd.h>

static NSString *m17path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m17_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOAcquisitionRun *m17BuildRunWithProvenance(void)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < 3; k++) {
        double mz[4], in[4];
        for (NSUInteger i = 0; i < 4; i++) {
            mz[i] = 100.0 + (double)(k * 4 + i);
            in[i] = (double)(k + 1) * 10.0 + (double)i;
        }
        TTIOEncodingSpec *enc =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                           compressionAlgorithm:TTIOCompressionZlib
                                      byteOrder:TTIOByteOrderLittleEndian];
        TTIOSignalArray *mzA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:sizeof(mz)]
                                              length:4
                                            encoding:enc
                                                axis:nil];
        TTIOSignalArray *inA =
            [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:sizeof(in)]
                                              length:4
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
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@"TestCo"
                                                     model:@"M17"
                                              serialNumber:@"00001"
                                                sourceType:@"ESI"
                                              analyzerType:@"Orbitrap"
                                              detectorType:@"inductive"];
    TTIOAcquisitionRun *run =
        [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                    acquisitionMode:TTIOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];

    TTIOProvenanceRecord *step1 =
        [[TTIOProvenanceRecord alloc] initWithInputRefs:@[@"raw:run_0001"]
                                                software:@"thermo-raw-parser/1.4"
                                              parameters:@{@"denoise": @"yes"}
                                              outputRefs:@[@"ttio:run_0001"]
                                           timestampUnix:1710000000];
    TTIOProvenanceRecord *step2 =
        [[TTIOProvenanceRecord alloc] initWithInputRefs:@[@"ttio:run_0001"]
                                                software:@"ttio-obj/0.3.0"
                                              parameters:@{@"mode": @"serialize"}
                                              outputRefs:@[@"ttio:run_0001"]
                                           timestampUnix:1710000100];
    [run addProcessingStep:step1];
    [run addProcessingStep:step2];
    return run;
}

static void m17WriteAndReopen(NSString *path)
{
    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"m17"
                                isaInvestigationId:@"TTIO:m17"
                                            msRuns:@{@"run_0001": m17BuildRunWithProvenance()}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    NSError *err = nil;
    PASS([ds writeToFilePath:path error:&err], "M17 dataset writes to disk");
    PASS(err == nil, "M17 write produces no error");
}

void testMilestone17(void)
{
    // ---- 1. Write a v0.3 file and verify compound + legacy mirror ----
    NSString *path = m17path(@"rt");
    unlink([path fileSystemRepresentation]);
    m17WriteAndReopen(path);

    // Root-level feature flags include compound_per_run_provenance.
    @autoreleasepool {
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        PASS(f != nil, "reopen for feature flag check");
        NSArray *features = [TTIOFeatureFlags featuresForRoot:[f rootGroup]];
        PASS([features containsObject:@"compound_per_run_provenance"],
             "compound_per_run_provenance feature flag present");
        (void)f;
    }

    // Both the compound subgroup and the legacy JSON mirror must exist.
    @autoreleasepool {
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Group *root  = [f rootGroup];
        TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
        TTIOHDF5Group *ms    = [study openGroupNamed:@"ms_runs" error:&err];
        TTIOHDF5Group *run   = [ms openGroupNamed:@"run_0001" error:&err];
        PASS([run hasChildNamed:@"provenance"],
             "compound per-run provenance subgroup written");
        TTIOHDF5Group *prov = [run openGroupNamed:@"provenance" error:&err];
        PASS([prov hasChildNamed:@"steps"],
             "per-run provenance/steps compound dataset written");
        PASS([run hasAttributeNamed:@"provenance_json"],
             "legacy @provenance_json mirror still emitted (signature compat)");
        (void)f;
    }

    // Round-trip the dataset and confirm the records decode correctly.
    @autoreleasepool {
        NSError *err = nil;
        TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(rt != nil, "reopen the round-tripped dataset");
        TTIOAcquisitionRun *run = rt.msRuns[@"run_0001"];
        PASS(run != nil, "round-tripped run is available");
        NSArray *steps = [run provenanceChain];
        PASS(steps.count == 2, "two provenance records decoded");
        if (steps.count == 2) {
            TTIOProvenanceRecord *s0 = steps[0];
            PASS([s0.software isEqualToString:@"thermo-raw-parser/1.4"],
                 "step 0 software matches");
            PASS(s0.timestampUnix == 1710000000, "step 0 timestamp matches");
            TTIOProvenanceRecord *s1 = steps[1];
            PASS([s1.software isEqualToString:@"ttio-obj/0.3.0"],
                 "step 1 software matches");
            PASS(s1.timestampUnix == 1710000100, "step 1 timestamp matches");
        }
    }
    unlink([path fileSystemRepresentation]);

    // ---- 2. Simulate a v0.2 file that only carries @provenance_json ----
    //
    // We write a normal v0.3 file, then manually unlink the compound
    // provenance subgroup via the raw HDF5 API. The reader must fall
    // back to the JSON attribute and still recover all records.
    NSString *path2 = m17path(@"legacy");
    unlink([path2 fileSystemRepresentation]);
    m17WriteAndReopen(path2);

    @autoreleasepool {
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path2 error:&err];
        PASS(f != nil, "reopen writable for compound removal");
        TTIOHDF5Group *root  = [f rootGroup];
        TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
        TTIOHDF5Group *ms    = [study openGroupNamed:@"ms_runs" error:&err];
        TTIOHDF5Group *run   = [ms openGroupNamed:@"run_0001" error:&err];
        // Unlink the entire `provenance` subgroup.
        herr_t rc = H5Ldelete(run.groupId, "provenance", H5P_DEFAULT);
        PASS(rc >= 0, "manually unlink compound per-run provenance subgroup");
        (void)f;
    }

    @autoreleasepool {
        NSError *err = nil;
        TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:path2 error:&err];
        PASS(rt != nil, "reopen dataset after compound removal");
        TTIOAcquisitionRun *run = rt.msRuns[@"run_0001"];
        NSArray *steps = [run provenanceChain];
        PASS(steps.count == 2,
             "legacy @provenance_json fallback recovers both records");
        if (steps.count == 2) {
            TTIOProvenanceRecord *s0 = steps[0];
            PASS([s0.software isEqualToString:@"thermo-raw-parser/1.4"],
                 "legacy fallback preserves step 0 software");
        }
    }
    unlink([path2 fileSystemRepresentation]);

    // ---- 3. Run with no provenance writes no compound subgroup ----
    NSString *path3 = m17path(@"empty");
    unlink([path3 fileSystemRepresentation]);

    TTIOAcquisitionRun *cleanRun = nil;
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 2; k++) {
            double mz[2] = { 100.0 + k, 101.0 + k };
            double in[2] = { 1.0, 2.0 };
            TTIOEncodingSpec *enc =
                [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                               compressionAlgorithm:TTIOCompressionZlib
                                          byteOrder:TTIOByteOrderLittleEndian];
            TTIOSignalArray *mzA =
                [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:sizeof(mz)]
                                                  length:2 encoding:enc axis:nil];
            TTIOSignalArray *inA =
                [[TTIOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:sizeof(in)]
                                                  length:2 encoding:enc axis:nil];
            [spectra addObject:
                [[TTIOMassSpectrum alloc] initWithMzArray:mzA
                                           intensityArray:inA
                                                  msLevel:1
                                                 polarity:TTIOPolarityPositive
                                               scanWindow:nil
                                            indexPosition:k
                                          scanTimeSeconds:0
                                              precursorMz:0
                                          precursorCharge:0
                                                    error:NULL]];
        }
        TTIOInstrumentConfig *cfg =
            [[TTIOInstrumentConfig alloc] initWithManufacturer:@"" model:@"" serialNumber:@""
                                                    sourceType:@"" analyzerType:@"" detectorType:@""];
        cleanRun = [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                               acquisitionMode:TTIOAcquisitionModeMS1DDA
                                              instrumentConfig:cfg];
    }
    TTIOSpectralDataset *dsEmpty =
        [[TTIOSpectralDataset alloc] initWithTitle:@"m17e"
                                isaInvestigationId:@""
                                            msRuns:@{@"run_0001": cleanRun}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    NSError *err = nil;
    PASS([dsEmpty writeToFilePath:path3 error:&err],
         "dataset with no per-run provenance writes cleanly");

    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path3 error:&err];
        TTIOHDF5Group *root  = [f rootGroup];
        TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
        TTIOHDF5Group *ms    = [study openGroupNamed:@"ms_runs" error:&err];
        TTIOHDF5Group *run   = [ms openGroupNamed:@"run_0001" error:&err];
        PASS(![run hasChildNamed:@"provenance"],
             "no compound per-run provenance subgroup when records are empty");
        PASS(![run hasAttributeNamed:@"provenance_json"],
             "no legacy @provenance_json attribute when records are empty");
        (void)f;
    }
    unlink([path3 fileSystemRepresentation]);
}
