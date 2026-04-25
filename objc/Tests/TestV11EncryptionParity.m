// v1.1 parity: encrypt -> close -> reopen -> isEncrypted -> decrypt -> read.
//
// Covers the two bugs reported in the TTI-O-MCP-Server M5 handoff:
//   * Issue A: TTIOSpectralDataset.isEncrypted / .encryptedAlgorithm lost
//     state across close/reopen because the @encrypted root attribute was
//     not being persisted.
//   * Issue B: -decryptWithKey:error: left TTIOMassSpectrum.intensityArray
//     unusable because the in-memory channel cache was never rehydrated
//     with plaintext after a round trip through disk.
//
// Mirrors python/tests/test_v1_1_encryption_parity.py and
// java/src/test/java/.../ProtectionTest.java#v11* so a regression in any
// one implementation is caught by the parity suite before a v1.1 release.
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

static NSString *v11path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_v11_parity_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOSignalArray *v11F64(const double *values, NSUInteger n)
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

static TTIOAcquisitionRun *v11MakeOneSpectrumRun(const double *intensity, NSUInteger n)
{
    double mzBuf[4] = {100.0, 200.0, 300.0, 400.0};
    assert(n == 4 && "fixture assumes 4-point spectrum");
    TTIOMassSpectrum *spec =
        [[TTIOMassSpectrum alloc] initWithMzArray:v11F64(mzBuf, n)
                                   intensityArray:v11F64(intensity, n)
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

static NSString *v11WriteFixture(NSString *suffix, const double *intensity)
{
    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"v11_parity"
                                isaInvestigationId:@""
                                            msRuns:@{@"run_0001": v11MakeOneSpectrumRun(intensity, 4)}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    NSString *path = v11path(suffix);
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    if (![ds writeToFilePath:path error:&err]) {
        NSLog(@"v11 fixture write failed: %@", err);
        return nil;
    }
    [ds closeFile];
    return path;
}

static NSData *v11KnownKey(void)
{
    uint8_t k[32];
    for (int i = 0; i < 32; i++) k[i] = (uint8_t)i;
    return [NSData dataWithBytes:k length:32];
}

// ---- Issue A: is_encrypted / encrypted_algorithm survive close/reopen ----
static void v11TestEncryptedStateSurvivesCloseReopen(void)
{
    double intensity[4] = {1.0, 2.0, 3.0, 4.0};
    NSString *path = v11WriteFixture(@"issueA", intensity);
    PASS(path != nil, "Issue A: fixture writes");

    NSData *key = v11KnownKey();
    NSError *err = nil;

    // Encrypt via a fresh read handle, mirroring the Python/Java parity
    // sequence. closeFile is required so the encryption manager can
    // reopen the file read-write.
    TTIOSpectralDataset *writer =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(writer != nil, "Issue A: initial read succeeds");
    PASS(!writer.isEncrypted,
         "Issue A: plaintext dataset reports isEncrypted == NO");
    PASS([writer.encryptedAlgorithm isEqualToString:@""],
         "Issue A: plaintext dataset reports empty encryptedAlgorithm");

    [writer closeFile];
    err = nil;
    BOOL enc = [writer encryptWithKey:key
                                level:TTIOEncryptionLevelDataset
                                error:&err];
    PASS(enc, "Issue A: encryptWithKey:level: succeeds");
    PASS(writer.isEncrypted,
         "Issue A: isEncrypted flips YES in-memory immediately after encrypt");
    PASS([writer.encryptedAlgorithm isEqualToString:@"aes-256-gcm"],
         "Issue A: encryptedAlgorithm is aes-256-gcm after encrypt");
    [writer closeFile];

    // Critical assertion: state must persist to disk and be visible to a
    // fresh reader (this was Issue A).
    err = nil;
    TTIOSpectralDataset *reader =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(reader != nil, "Issue A: reopen after encrypt succeeds");
    PASS(reader.isEncrypted,
         "Issue A: reopened dataset reports isEncrypted == YES");
    PASS([reader.encryptedAlgorithm isEqualToString:@"aes-256-gcm"],
         "Issue A: reopened dataset reports aes-256-gcm");
    [reader closeFile];

    unlink([path fileSystemRepresentation]);
}

// ---- Issue B: decrypt rehydrates in-memory intensity channel ----
static void v11TestDecryptRehydratesIntensity(void)
{
    double intensity[4] = {1.0, 2.0, 3.0, 4.0};
    NSString *path = v11WriteFixture(@"issueB", intensity);
    PASS(path != nil, "Issue B: fixture writes");

    NSData *key = v11KnownKey();
    NSError *err = nil;

    TTIOSpectralDataset *writer =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(writer != nil, "Issue B: initial read succeeds");
    [writer closeFile];
    err = nil;
    PASS([writer encryptWithKey:key
                          level:TTIOEncryptionLevelDataset
                          error:&err],
         "Issue B: encryptWithKey:level: succeeds");
    [writer closeFile];

    err = nil;
    TTIOSpectralDataset *sealed =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(sealed.isEncrypted, "Issue B: reopened dataset is encrypted");
    err = nil;
    PASS([sealed decryptWithKey:key error:&err],
         "Issue B: decryptWithKey: succeeds on reopened dataset");

    TTIOAcquisitionRun *run = sealed.msRuns[@"run_0001"];
    PASS(run != nil, "Issue B: run_0001 present after decrypt");

    err = nil;
    id specAny = [run spectrumAtIndex:0 error:&err];
    PASS([specAny isKindOfClass:[TTIOMassSpectrum class]],
         "Issue B: spectrumAtIndex:0: returns TTIOMassSpectrum");

    TTIOMassSpectrum *spec = (TTIOMassSpectrum *)specAny;
    TTIOSignalArray *intensityArr = spec.intensityArray;
    PASS(intensityArr != nil,
         "Issue B: decrypted spectrum exposes non-nil intensityArray "
         "(this was the KeyError-equivalent before the fix)");
    PASS(intensityArr.length == 4,
         "Issue B: decrypted intensity length matches original");

    if (intensityArr.length == 4 && intensityArr.buffer.length == 4 * sizeof(double)) {
        const double *out = (const double *)intensityArr.buffer.bytes;
        BOOL match = YES;
        for (NSUInteger i = 0; i < 4; i++) {
            if (out[i] != intensity[i]) { match = NO; break; }
        }
        PASS(match, "Issue B: decrypted intensity bytes equal plaintext");
    } else {
        PASS(NO, "Issue B: decrypted intensity has unexpected shape");
    }

    [sealed closeFile];
    unlink([path fileSystemRepresentation]);
}

void testV11EncryptionParity(void)
{
    v11TestEncryptedStateSurvivesCloseReopen();
    v11TestDecryptRehydratesIntensity();
}
