#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/TTIOIsolationWindow.h"
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOFeatureFlags.h"
#import <unistd.h>

static TTIOSignalArray *float64Array(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static TTIOIsolationWindow *roundTrip(TTIOIsolationWindow *w)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:w];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testIsolationWindow(void)
{
    // ---- construction ----
    TTIOIsolationWindow *w = [TTIOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:1.0
                                                         upperOffset:2.0];
    PASS(w != nil, "TTIOIsolationWindow constructible");
    PASS(w.targetMz == 500.0, "targetMz stored");
    PASS(w.lowerOffset == 1.0, "lowerOffset stored");
    PASS(w.upperOffset == 2.0, "upperOffset stored");
    PASS([w lowerBound] == 499.0, "lowerBound = target - lowerOffset");
    PASS([w upperBound] == 502.0, "upperBound = target + upperOffset");
    PASS([w width] == 3.0, "width = lowerOffset + upperOffset");

    // ---- equality ----
    TTIOIsolationWindow *a = [TTIOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:0.5
                                                         upperOffset:0.5];
    TTIOIsolationWindow *b = [TTIOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:0.5
                                                         upperOffset:0.5];
    TTIOIsolationWindow *c = [TTIOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:0.5
                                                         upperOffset:1.0];
    PASS([a isEqual:b] && [b isEqual:a], "isEqual: symmetric for equal values");
    PASS(![a isEqual:c], "isEqual: distinguishes upperOffset");
    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS([a hash] == [b hash], "equal objects produce equal hashes");

    // ---- copying (immutable: copy returns self) ----
    TTIOIsolationWindow *copy = [a copy];
    PASS(copy == a, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    TTIOIsolationWindow *decoded = roundTrip(a);
    PASS([decoded isEqual:a], "NSCoding round-trip preserves value");
    PASS(decoded != a, "decoded is a fresh instance");
}

void testActivationMethodEnum(void)
{
    // M74: values persist as int32 in spectrum_index; must match Python/Java.
    PASS(TTIOActivationMethodNone  == 0, "ActivationMethod.None = 0");
    PASS(TTIOActivationMethodCID   == 1, "ActivationMethod.CID  = 1");
    PASS(TTIOActivationMethodHCD   == 2, "ActivationMethod.HCD  = 2");
    PASS(TTIOActivationMethodETD   == 3, "ActivationMethod.ETD  = 3");
    PASS(TTIOActivationMethodUVPD  == 4, "ActivationMethod.UVPD = 4");
    PASS(TTIOActivationMethodECD   == 5, "ActivationMethod.ECD  = 5");
    PASS(TTIOActivationMethodEThcD == 6, "ActivationMethod.EThcD= 6");
}

void testMassSpectrumActivationAndIsolationFields(void)
{
    double mzVals[] = { 100.0, 200.0 };
    double intVals[] = { 1.0, 2.0 };
    TTIOSignalArray *mz = float64Array(mzVals, 2);
    TTIOSignalArray *intens = float64Array(intVals, 2);

    // Backward-compatible initializer defaults new fields.
    NSError *err = nil;
    TTIOMassSpectrum *ms1 = [[TTIOMassSpectrum alloc]
        initWithMzArray:mz intensityArray:intens
                msLevel:1 polarity:TTIOPolarityPositive
             scanWindow:nil
          indexPosition:0 scanTimeSeconds:0.0
            precursorMz:0.0 precursorCharge:0 error:&err];
    PASS(ms1 != nil, "backward-compat init builds MassSpectrum");
    PASS(ms1.activationMethod == TTIOActivationMethodNone,
         "backward-compat defaults activationMethod to None");
    PASS(ms1.isolationWindow == nil,
         "backward-compat defaults isolationWindow to nil");

    // Full initializer populates both.
    TTIOIsolationWindow *iw = [TTIOIsolationWindow windowWithTargetMz:500.0
                                                          lowerOffset:1.0
                                                          upperOffset:1.0];
    TTIOMassSpectrum *ms2 = [[TTIOMassSpectrum alloc]
        initWithMzArray:mz intensityArray:intens
                msLevel:2 polarity:TTIOPolarityPositive
             scanWindow:nil
       activationMethod:TTIOActivationMethodHCD
        isolationWindow:iw
          indexPosition:1 scanTimeSeconds:1.5
            precursorMz:500.0 precursorCharge:2 error:&err];
    PASS(ms2 != nil, "M74 init builds MassSpectrum");
    PASS(ms2.activationMethod == TTIOActivationMethodHCD,
         "activationMethod stored");
    PASS(ms2.isolationWindow == iw, "isolationWindow stored");
    PASS(ms2.isolationWindow.targetMz == 500.0,
         "isolationWindow.targetMz reachable via property");
}

// -------- M74 Slice B: TTIOSpectrumIndex round-trip --------

static NSString *m74IndexPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m74idx_%d_%@.tio",
            (int)getpid(), suffix];
}

void testSpectrumIndexM74RoundTrip(void)
{
    // Helper to build the 8 legacy columns for a 3-spectrum index.
    NSUInteger n = 3;
    uint64_t offs[3]   = {0, 10, 20};
    uint32_t lens[3]   = {10, 10, 10};
    double   rts[3]    = {0.0, 0.5, 1.0};
    int32_t  mls[3]    = {1, 2, 2};
    int32_t  pols[3]   = {1, 1, 1};
    double   pmzs[3]   = {0.0, 500.0, 750.5};
    int32_t  pcs[3]    = {0, 2, 1};
    double   bpis[3]   = {1000.0, 2000.0, 3000.0};
    NSData *offsD   = [NSData dataWithBytes:offs length:sizeof(offs)];
    NSData *lensD   = [NSData dataWithBytes:lens length:sizeof(lens)];
    NSData *rtsD    = [NSData dataWithBytes:rts  length:sizeof(rts)];
    NSData *mlsD    = [NSData dataWithBytes:mls  length:sizeof(mls)];
    NSData *polsD   = [NSData dataWithBytes:pols length:sizeof(pols)];
    NSData *pmzsD   = [NSData dataWithBytes:pmzs length:sizeof(pmzs)];
    NSData *pcsD    = [NSData dataWithBytes:pcs  length:sizeof(pcs)];
    NSData *bpisD   = [NSData dataWithBytes:bpis length:sizeof(bpis)];

    // ---- legacy path (no M74 columns) ----
    {
        TTIOSpectrumIndex *idx =
            [[TTIOSpectrumIndex alloc] initWithOffsets:offsD
                                                lengths:lensD
                                         retentionTimes:rtsD
                                               msLevels:mlsD
                                             polarities:polsD
                                           precursorMzs:pmzsD
                                       precursorCharges:pcsD
                                     basePeakIntensities:bpisD];
        PASS(idx.count == n, "legacy SpectrumIndex count == 3");
        PASS(!idx.hasActivationDetail, "legacy SpectrumIndex hasActivationDetail == NO");
        PASS([idx activationMethodAt:1] == TTIOActivationMethodNone,
             "legacy activationMethodAt returns None sentinel");
        PASS([idx isolationWindowAt:1] == nil,
             "legacy isolationWindowAt returns nil");

        NSString *path = m74IndexPath(@"legacy");
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        PASS([idx writeToGroup:[f rootGroup] error:&err], "legacy index writes");
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOSpectrumIndex *back =
            [TTIOSpectrumIndex readFromGroup:[g rootGroup] error:&err];
        PASS(back != nil, "legacy index reads back");
        PASS(!back.hasActivationDetail, "read-back legacy has no M74 columns");
        PASS([back activationMethodAt:0] == TTIOActivationMethodNone,
             "read-back legacy activationMethodAt is None");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- M74 path (all four columns populated) ----
    {
        int32_t acts[3] = { TTIOActivationMethodNone,
                            TTIOActivationMethodHCD,
                            TTIOActivationMethodCID };
        double  itgt[3] = { 0.0, 500.0, 750.5 };
        double  ilo[3]  = { 0.0, 1.0, 0.5 };
        double  ihi[3]  = { 0.0, 2.0, 0.75 };
        NSData *actsD = [NSData dataWithBytes:acts length:sizeof(acts)];
        NSData *itgtD = [NSData dataWithBytes:itgt length:sizeof(itgt)];
        NSData *iloD  = [NSData dataWithBytes:ilo  length:sizeof(ilo)];
        NSData *ihiD  = [NSData dataWithBytes:ihi  length:sizeof(ihi)];

        TTIOSpectrumIndex *idx =
            [[TTIOSpectrumIndex alloc] initWithOffsets:offsD
                                                lengths:lensD
                                         retentionTimes:rtsD
                                               msLevels:mlsD
                                             polarities:polsD
                                           precursorMzs:pmzsD
                                       precursorCharges:pcsD
                                     basePeakIntensities:bpisD
                                       activationMethods:actsD
                                      isolationTargetMzs:itgtD
                                   isolationLowerOffsets:iloD
                                   isolationUpperOffsets:ihiD];
        PASS(idx.hasActivationDetail, "M74 SpectrumIndex hasActivationDetail == YES");
        PASS([idx activationMethodAt:1] == TTIOActivationMethodHCD,
             "M74 activationMethodAt returns HCD");
        PASS([idx isolationWindowAt:0] == nil,
             "MS1 sentinel: isolationWindowAt(0) == nil");
        TTIOIsolationWindow *w1 = [idx isolationWindowAt:1];
        PASS(w1 != nil && w1.targetMz == 500.0 && w1.lowerOffset == 1.0
             && w1.upperOffset == 2.0,
             "M74 isolationWindowAt(1) returns populated window");

        NSString *path = m74IndexPath(@"full");
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        PASS([idx writeToGroup:[f rootGroup] error:&err], "M74 index writes");
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOSpectrumIndex *back =
            [TTIOSpectrumIndex readFromGroup:[g rootGroup] error:&err];
        PASS(back != nil, "M74 index reads back");
        PASS(back.hasActivationDetail, "read-back M74 hasActivationDetail == YES");
        PASS([back activationMethodAt:2] == TTIOActivationMethodCID,
             "read-back M74 activationMethodAt(2) == CID");
        TTIOIsolationWindow *w2 = [back isolationWindowAt:2];
        PASS(w2 != nil && w2.targetMz == 750.5 && [w2 width] == 1.25,
             "read-back M74 isolationWindowAt(2) reconstructs window");
        PASS([back isolationWindowAt:0] == nil,
             "read-back MS1 sentinel stays nil");
        [g close];
        unlink([path fileSystemRepresentation]);
    }
}

// -------- M74 Slice E: feature flag (v1.0 unified version) --------
//
// Writing a dataset whose runs carry the four optional M74 columns must
// advertise `opt_ms2_activation_detail` in @ttio_features. v1.0 reset:
// @ttio_format_version is a single "1.0" stamp regardless of which
// optional columns / features are present; readers gate behavior on the
// @ttio_features list, not per-feature version equality.

static TTIOMassSpectrum *m74SliceEMakeSpec(int msLevel,
                                             TTIOActivationMethod m,
                                             TTIOIsolationWindow *iw,
                                             NSUInteger idxPos)
{
    double mzVals[] = {100.0, 101.0, 102.0};
    double inVals[] = {10.0, 20.0, 30.0};
    TTIOSignalArray *mz = float64Array(mzVals, 3);
    TTIOSignalArray *in = float64Array(inVals, 3);
    NSError *err = nil;
    return [[TTIOMassSpectrum alloc] initWithMzArray:mz
                                      intensityArray:in
                                             msLevel:msLevel
                                            polarity:TTIOPolarityPositive
                                          scanWindow:nil
                                    activationMethod:m
                                     isolationWindow:iw
                                       indexPosition:idxPos
                                     scanTimeSeconds:(double)idxPos
                                         precursorMz:(iw ? iw.targetMz : 0.0)
                                     precursorCharge:(iw ? 2 : 0)
                                               error:&err];
}

static TTIOAcquisitionRun *m74SliceEMakeRun(BOOL withM74)
{
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    TTIOMassSpectrum *ms1 =
        m74SliceEMakeSpec(1, TTIOActivationMethodNone, nil, 0);
    NSArray *spectra;
    if (withM74) {
        TTIOIsolationWindow *iw =
            [TTIOIsolationWindow windowWithTargetMz:445.3
                                         lowerOffset:0.5
                                         upperOffset:0.5];
        TTIOMassSpectrum *ms2 =
            m74SliceEMakeSpec(2, TTIOActivationMethodHCD, iw, 1);
        spectra = @[ms1, ms2];
    } else {
        spectra = @[ms1];
    }
    return [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:TTIOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

void testSpectralDatasetM74FeatureFlag(void)
{
    NSString *legacyPath = [NSString stringWithFormat:
        @"/tmp/ttio_test_m74sliceE_legacy_%d.tio", (int)getpid()];
    NSString *m74Path = [NSString stringWithFormat:
        @"/tmp/ttio_test_m74sliceE_m74_%d.tio", (int)getpid()];
    unlink([legacyPath fileSystemRepresentation]);
    unlink([m74Path fileSystemRepresentation]);

    // ---- Legacy dataset: no M74 content, stamps unified "1.0" ----
    @autoreleasepool {
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"legacy"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m74SliceEMakeRun(NO)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSError *err = nil;
        PASS([ds writeToFilePath:legacyPath error:&err],
             "Slice E: legacy dataset writes");

        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:legacyPath error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        NSString *version = [TTIOFeatureFlags formatVersionForRoot:root];
        NSArray *features = [TTIOFeatureFlags featuresForRoot:root];
        PASS([version isEqualToString:@"1.0"],
             "Slice E: legacy file stamps unified format version 1.0");
        PASS(![features containsObject:@"opt_ms2_activation_detail"],
             "Slice E: legacy file does not advertise opt_ms2_activation_detail");
        [f close];
    }

    // ---- M74 dataset: activation column present, bumps to "1.3" ----
    @autoreleasepool {
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m74"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m74SliceEMakeRun(YES)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSError *err = nil;
        PASS([ds writeToFilePath:m74Path error:&err],
             "Slice E: M74 dataset writes");

        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:m74Path error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        NSString *version = [TTIOFeatureFlags formatVersionForRoot:root];
        NSArray *features = [TTIOFeatureFlags featuresForRoot:root];
        PASS([version isEqualToString:@"1.0"],
             "Slice E: M74 file stamps unified format version 1.0");
        PASS([features containsObject:[TTIOFeatureFlags featureMS2ActivationDetail]],
             "Slice E: M74 file advertises opt_ms2_activation_detail");
        PASS([TTIOFeatureFlags root:root
                    supportsFeature:[TTIOFeatureFlags featureMS2ActivationDetail]],
             "Slice E: root:supportsFeature: returns YES for M74 flag");
        [f close];

        // Round-trip: reading back must preserve M74 columns + index.
        TTIOSpectralDataset *rt =
            [TTIOSpectralDataset readFromFilePath:m74Path error:&err];
        PASS(rt != nil, "Slice E: M74 file reads back via full dataset reader");
        TTIOAcquisitionRun *run = rt.msRuns[@"run_0001"];
        PASS(run.spectrumIndex.hasActivationDetail,
             "Slice E: round-tripped run preserves M74 columns");
        PASS([run.spectrumIndex activationMethodAt:1] == TTIOActivationMethodHCD,
             "Slice E: round-tripped index records HCD at position 1");
    }

    unlink([legacyPath fileSystemRepresentation]);
    unlink([m74Path fileSystemRepresentation]);
}
