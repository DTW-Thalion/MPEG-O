#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/MPGOIsolationWindow.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "Run/MPGOSpectrumIndex.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import <unistd.h>

static MPGOSignalArray *float64Array(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static MPGOIsolationWindow *roundTrip(MPGOIsolationWindow *w)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:w];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testIsolationWindow(void)
{
    // ---- construction ----
    MPGOIsolationWindow *w = [MPGOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:1.0
                                                         upperOffset:2.0];
    PASS(w != nil, "MPGOIsolationWindow constructible");
    PASS(w.targetMz == 500.0, "targetMz stored");
    PASS(w.lowerOffset == 1.0, "lowerOffset stored");
    PASS(w.upperOffset == 2.0, "upperOffset stored");
    PASS([w lowerBound] == 499.0, "lowerBound = target - lowerOffset");
    PASS([w upperBound] == 502.0, "upperBound = target + upperOffset");
    PASS([w width] == 3.0, "width = lowerOffset + upperOffset");

    // ---- equality ----
    MPGOIsolationWindow *a = [MPGOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:0.5
                                                         upperOffset:0.5];
    MPGOIsolationWindow *b = [MPGOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:0.5
                                                         upperOffset:0.5];
    MPGOIsolationWindow *c = [MPGOIsolationWindow windowWithTargetMz:500.0
                                                         lowerOffset:0.5
                                                         upperOffset:1.0];
    PASS([a isEqual:b] && [b isEqual:a], "isEqual: symmetric for equal values");
    PASS(![a isEqual:c], "isEqual: distinguishes upperOffset");
    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS([a hash] == [b hash], "equal objects produce equal hashes");

    // ---- copying (immutable: copy returns self) ----
    MPGOIsolationWindow *copy = [a copy];
    PASS(copy == a, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    MPGOIsolationWindow *decoded = roundTrip(a);
    PASS([decoded isEqual:a], "NSCoding round-trip preserves value");
    PASS(decoded != a, "decoded is a fresh instance");
}

void testActivationMethodEnum(void)
{
    // M74: values persist as int32 in spectrum_index; must match Python/Java.
    PASS(MPGOActivationMethodNone  == 0, "ActivationMethod.None = 0");
    PASS(MPGOActivationMethodCID   == 1, "ActivationMethod.CID  = 1");
    PASS(MPGOActivationMethodHCD   == 2, "ActivationMethod.HCD  = 2");
    PASS(MPGOActivationMethodETD   == 3, "ActivationMethod.ETD  = 3");
    PASS(MPGOActivationMethodUVPD  == 4, "ActivationMethod.UVPD = 4");
    PASS(MPGOActivationMethodECD   == 5, "ActivationMethod.ECD  = 5");
    PASS(MPGOActivationMethodEThcD == 6, "ActivationMethod.EThcD= 6");
}

void testMassSpectrumActivationAndIsolationFields(void)
{
    double mzVals[] = { 100.0, 200.0 };
    double intVals[] = { 1.0, 2.0 };
    MPGOSignalArray *mz = float64Array(mzVals, 2);
    MPGOSignalArray *intens = float64Array(intVals, 2);

    // Backward-compatible initializer defaults new fields.
    NSError *err = nil;
    MPGOMassSpectrum *ms1 = [[MPGOMassSpectrum alloc]
        initWithMzArray:mz intensityArray:intens
                msLevel:1 polarity:MPGOPolarityPositive
             scanWindow:nil
          indexPosition:0 scanTimeSeconds:0.0
            precursorMz:0.0 precursorCharge:0 error:&err];
    PASS(ms1 != nil, "backward-compat init builds MassSpectrum");
    PASS(ms1.activationMethod == MPGOActivationMethodNone,
         "backward-compat defaults activationMethod to None");
    PASS(ms1.isolationWindow == nil,
         "backward-compat defaults isolationWindow to nil");

    // Full initializer populates both.
    MPGOIsolationWindow *iw = [MPGOIsolationWindow windowWithTargetMz:500.0
                                                          lowerOffset:1.0
                                                          upperOffset:1.0];
    MPGOMassSpectrum *ms2 = [[MPGOMassSpectrum alloc]
        initWithMzArray:mz intensityArray:intens
                msLevel:2 polarity:MPGOPolarityPositive
             scanWindow:nil
       activationMethod:MPGOActivationMethodHCD
        isolationWindow:iw
          indexPosition:1 scanTimeSeconds:1.5
            precursorMz:500.0 precursorCharge:2 error:&err];
    PASS(ms2 != nil, "M74 init builds MassSpectrum");
    PASS(ms2.activationMethod == MPGOActivationMethodHCD,
         "activationMethod stored");
    PASS(ms2.isolationWindow == iw, "isolationWindow stored");
    PASS(ms2.isolationWindow.targetMz == 500.0,
         "isolationWindow.targetMz reachable via property");
}

// -------- M74 Slice B: MPGOSpectrumIndex round-trip --------

static NSString *m74IndexPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m74idx_%d_%@.mpgo",
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
        MPGOSpectrumIndex *idx =
            [[MPGOSpectrumIndex alloc] initWithOffsets:offsD
                                                lengths:lensD
                                         retentionTimes:rtsD
                                               msLevels:mlsD
                                             polarities:polsD
                                           precursorMzs:pmzsD
                                       precursorCharges:pcsD
                                     basePeakIntensities:bpisD];
        PASS(idx.count == n, "legacy SpectrumIndex count == 3");
        PASS(!idx.hasActivationDetail, "legacy SpectrumIndex hasActivationDetail == NO");
        PASS([idx activationMethodAt:1] == MPGOActivationMethodNone,
             "legacy activationMethodAt returns None sentinel");
        PASS([idx isolationWindowAt:1] == nil,
             "legacy isolationWindowAt returns nil");

        NSString *path = m74IndexPath(@"legacy");
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([idx writeToGroup:[f rootGroup] error:&err], "legacy index writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOSpectrumIndex *back =
            [MPGOSpectrumIndex readFromGroup:[g rootGroup] error:&err];
        PASS(back != nil, "legacy index reads back");
        PASS(!back.hasActivationDetail, "read-back legacy has no M74 columns");
        PASS([back activationMethodAt:0] == MPGOActivationMethodNone,
             "read-back legacy activationMethodAt is None");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- M74 path (all four columns populated) ----
    {
        int32_t acts[3] = { MPGOActivationMethodNone,
                            MPGOActivationMethodHCD,
                            MPGOActivationMethodCID };
        double  itgt[3] = { 0.0, 500.0, 750.5 };
        double  ilo[3]  = { 0.0, 1.0, 0.5 };
        double  ihi[3]  = { 0.0, 2.0, 0.75 };
        NSData *actsD = [NSData dataWithBytes:acts length:sizeof(acts)];
        NSData *itgtD = [NSData dataWithBytes:itgt length:sizeof(itgt)];
        NSData *iloD  = [NSData dataWithBytes:ilo  length:sizeof(ilo)];
        NSData *ihiD  = [NSData dataWithBytes:ihi  length:sizeof(ihi)];

        MPGOSpectrumIndex *idx =
            [[MPGOSpectrumIndex alloc] initWithOffsets:offsD
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
        PASS([idx activationMethodAt:1] == MPGOActivationMethodHCD,
             "M74 activationMethodAt returns HCD");
        PASS([idx isolationWindowAt:0] == nil,
             "MS1 sentinel: isolationWindowAt(0) == nil");
        MPGOIsolationWindow *w1 = [idx isolationWindowAt:1];
        PASS(w1 != nil && w1.targetMz == 500.0 && w1.lowerOffset == 1.0
             && w1.upperOffset == 2.0,
             "M74 isolationWindowAt(1) returns populated window");

        NSString *path = m74IndexPath(@"full");
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([idx writeToGroup:[f rootGroup] error:&err], "M74 index writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOSpectrumIndex *back =
            [MPGOSpectrumIndex readFromGroup:[g rootGroup] error:&err];
        PASS(back != nil, "M74 index reads back");
        PASS(back.hasActivationDetail, "read-back M74 hasActivationDetail == YES");
        PASS([back activationMethodAt:2] == MPGOActivationMethodCID,
             "read-back M74 activationMethodAt(2) == CID");
        MPGOIsolationWindow *w2 = [back isolationWindowAt:2];
        PASS(w2 != nil && w2.targetMz == 750.5 && [w2 width] == 1.25,
             "read-back M74 isolationWindowAt(2) reconstructs window");
        PASS([back isolationWindowAt:0] == nil,
             "read-back MS1 sentinel stays nil");
        [g close];
        unlink([path fileSystemRepresentation]);
    }
}
