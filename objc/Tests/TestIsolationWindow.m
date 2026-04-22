#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/MPGOIsolationWindow.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"

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
