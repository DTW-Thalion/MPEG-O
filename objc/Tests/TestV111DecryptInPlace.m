// v1.1.1 parity: +[TTIOSpectralDataset decryptInPlaceAtPath:withKey:error:].
//
// Covers the upstream-first piece of the TTI-O-MCP-Server M5
// ttio_decrypt_file tool: the existing v1.1.0 -decryptWithKey:error: is
// read-only, so the admin flow that writes plaintext back to disk needs a
// dedicated API. This suite verifies the classmethod reverses
// -encryptWithKey:level:TTIOEncryptionLevelDataset: across single- and
// multi-run fixtures, leaving the file byte-compatible with its
// pre-encryption state.
//
// Mirrors python/tests/test_v1_1_1_decrypt_in_place.py and
// java/src/test/java/.../ProtectionTest.java#decryptInPlace* so a
// regression in any one implementation is caught by the parity suite
// before a v1.1.1 release.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import <unistd.h>
#import <assert.h>

static NSString *v111path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_v111_decrypt_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOSignalArray *v111F64(const double *values, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:values length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static TTIOAcquisitionRun *v111MakeOneSpectrumRun(const double *intensity, NSUInteger n)
{
    double mzBuf[4] = {100.0, 200.0, 300.0, 400.0};
    assert(n == 4 && "fixture assumes 4-point spectrum");
    TTIOMassSpectrum *spec =
        [[TTIOMassSpectrum alloc] initWithMzArray:v111F64(mzBuf, n)
                                   intensityArray:v111F64(intensity, n)
                                          msLevel:1
                                         polarity:TTIOPolarityPositive
                                       scanWindow:nil
                                    indexPosition:0
                                  scanTimeSeconds:0.0
                                      precursorMz:0.0
                                  precursorCharge:0
                                            error:NULL];
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    return [[TTIOAcquisitionRun alloc] initWithSpectra:@[spec]
                                       acquisitionMode:TTIOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

static NSString *v111WriteFixture(NSString *suffix,
                                  NSArray<NSString *> *runNames,
                                  const double *intensity)
{
    NSMutableDictionary<NSString *, TTIOAcquisitionRun *> *runs =
        [NSMutableDictionary dictionary];
    for (NSString *name in runNames) {
        runs[name] = v111MakeOneSpectrumRun(intensity, 4);
    }
    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"v111_decrypt"
                                isaInvestigationId:@""
                                            msRuns:runs
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    NSString *path = v111path(suffix);
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    if (![ds writeToFilePath:path error:&err]) {
        NSLog(@"v111 fixture write failed: %@", err);
        return nil;
    }
    [ds closeFile];
    return path;
}

static NSData *v111KnownKey(void)
{
    uint8_t k[32];
    for (int i = 0; i < 32; i++) k[i] = (uint8_t)i;
    return [NSData dataWithBytes:k length:32];
}

static BOOL v111MatchesExpected(TTIOSignalArray *arr, const double *expected, NSUInteger n)
{
    if (!arr || arr.length != n) return NO;
    if (arr.buffer.length != n * sizeof(double)) return NO;
    const double *out = (const double *)arr.buffer.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        if (out[i] != expected[i]) return NO;
    }
    return YES;
}

// ---- single-run round-trip: encrypt -> decryptInPlace -> reopen plaintext ----
static void v111TestSingleRunRoundTrip(void)
{
    double intensity[4] = {1.0, 2.0, 3.0, 4.0};
    NSString *path = v111WriteFixture(@"single", @[@"run_0001"], intensity);
    PASS(path != nil, "single-run: fixture writes");

    NSData *key = v111KnownKey();
    NSError *err = nil;

    TTIOSpectralDataset *writer =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(writer != nil, "single-run: initial read succeeds");
    [writer closeFile];
    err = nil;
    PASS([writer encryptWithKey:key
                          level:TTIOEncryptionLevelDataset
                          error:&err],
         "single-run: encryptWithKey: succeeds");
    [writer closeFile];

    err = nil;
    BOOL ok = [TTIOSpectralDataset decryptInPlaceAtPath:path
                                                withKey:key
                                                  error:&err];
    PASS(ok, "single-run: decryptInPlaceAtPath: succeeds");

    // A fresh reader must see isEncrypted == NO and usable intensities.
    err = nil;
    TTIOSpectralDataset *reopened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(reopened != nil, "single-run: reopen after decryptInPlace succeeds");
    PASS(!reopened.isEncrypted,
         "single-run: reopened dataset reports isEncrypted == NO");
    PASS([reopened.encryptedAlgorithm isEqualToString:@""],
         "single-run: encryptedAlgorithm cleared");

    TTIOAcquisitionRun *run = reopened.msRuns[@"run_0001"];
    err = nil;
    id specAny = [run spectrumAtIndex:0 error:&err];
    TTIOMassSpectrum *spec = (TTIOMassSpectrum *)specAny;
    PASS(v111MatchesExpected(spec.intensityArray, intensity, 4),
         "single-run: decrypted intensity bytes equal plaintext");

    [reopened closeFile];
    unlink([path fileSystemRepresentation]);
}

// ---- multi-run: every run's intensity channel is restored ----
static void v111TestMultiRunRoundTrip(void)
{
    double intensity[4] = {1.0, 2.0, 3.0, 4.0};
    NSString *path = v111WriteFixture(@"multi",
                                      @[@"run_A", @"run_B", @"run_C"],
                                      intensity);
    PASS(path != nil, "multi-run: fixture writes");

    NSData *key = v111KnownKey();
    NSError *err = nil;

    TTIOSpectralDataset *writer =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(writer != nil, "multi-run: initial read succeeds");
    [writer closeFile];
    err = nil;
    PASS([writer encryptWithKey:key
                          level:TTIOEncryptionLevelDataset
                          error:&err],
         "multi-run: encryptWithKey: succeeds");
    [writer closeFile];

    err = nil;
    PASS([TTIOSpectralDataset decryptInPlaceAtPath:path
                                           withKey:key
                                             error:&err],
         "multi-run: decryptInPlaceAtPath: succeeds");

    err = nil;
    TTIOSpectralDataset *reopened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(!reopened.isEncrypted,
         "multi-run: reopened dataset reports isEncrypted == NO");

    for (NSString *name in @[@"run_A", @"run_B", @"run_C"]) {
        TTIOAcquisitionRun *run = reopened.msRuns[name];
        err = nil;
        TTIOMassSpectrum *spec =
            (TTIOMassSpectrum *)[run spectrumAtIndex:0 error:&err];
        PASS(v111MatchesExpected(spec.intensityArray, intensity, 4),
             "multi-run: all runs' intensities equal plaintext");
    }

    [reopened closeFile];
    unlink([path fileSystemRepresentation]);
}

// ---- idempotence: calling on an already-plaintext file is a no-op ----
static void v111TestIdempotentOnPlaintext(void)
{
    double intensity[4] = {1.0, 2.0, 3.0, 4.0};
    NSString *path = v111WriteFixture(@"plaintext", @[@"run_0001"], intensity);
    PASS(path != nil, "idempotent: fixture writes");

    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset decryptInPlaceAtPath:path
                                                withKey:v111KnownKey()
                                                  error:&err];
    PASS(ok, "idempotent: decryptInPlaceAtPath: on plaintext file succeeds");

    err = nil;
    TTIOSpectralDataset *reopened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(!reopened.isEncrypted,
         "idempotent: plaintext file still reports isEncrypted == NO");
    TTIOAcquisitionRun *run = reopened.msRuns[@"run_0001"];
    err = nil;
    TTIOMassSpectrum *spec =
        (TTIOMassSpectrum *)[run spectrumAtIndex:0 error:&err];
    PASS(v111MatchesExpected(spec.intensityArray, intensity, 4),
         "idempotent: intensities unchanged");

    [reopened closeFile];
    unlink([path fileSystemRepresentation]);
}

// ---- input validation: wrong key length rejected ----
static void v111TestRejectsShortKey(void)
{
    double intensity[4] = {1.0, 2.0, 3.0, 4.0};
    NSString *path = v111WriteFixture(@"shortkey", @[@"run_0001"], intensity);
    PASS(path != nil, "reject: fixture writes");

    NSData *shortKey = [@"too short" dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset decryptInPlaceAtPath:path
                                                withKey:shortKey
                                                  error:&err];
    PASS(!ok, "reject: decryptInPlaceAtPath: fails on short key");
    PASS(err != nil, "reject: populates NSError on short key");

    unlink([path fileSystemRepresentation]);
}

void testV111DecryptInPlace(void)
{
    v111TestSingleRunRoundTrip();
    v111TestMultiRunRoundTrip();
    v111TestIdempotentOnPlaintext();
    v111TestRejectsShortKey();
}
