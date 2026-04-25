// This test set intentionally covers the deprecated file-path encryption
// API. M10 acceptance criteria include "deprecated API still works".
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Protection/TTIOEncryptionManager.h"
#import "Protection/TTIOAccessPolicy.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <unistd.h>

static NSString *encPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_enc_%d_%@.tio",
            (int)getpid(), suffix];
}

static NSData *make32ByteKey(uint8_t seed)
{
    uint8_t buf[32];
    for (int i = 0; i < 32; i++) buf[i] = seed + i;
    return [NSData dataWithBytes:buf length:32];
}

static TTIOSignalArray *f64(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf length:n encoding:enc axis:nil];
}

static TTIOAcquisitionRun *buildSmallRun(void)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < 5; k++) {
        const NSUInteger N = 8;
        double mz[8], in[8];
        for (NSUInteger i = 0; i < N; i++) {
            mz[i] = 100.0 + (double)k + (double)i;
            in[i] = (double)(k * 100 + i);
        }
        NSError *err = nil;
        [spectra addObject:
            [[TTIOMassSpectrum alloc] initWithMzArray:f64(mz, N)
                                       intensityArray:f64(in, N)
                                              msLevel:1
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.5
                                          precursorMz:0
                                      precursorCharge:0
                                                error:&err]];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                     model:@"QE"
                                              serialNumber:@"S"
                                                sourceType:@"ESI"
                                              analyzerType:@"Orbitrap"
                                              detectorType:@"em"];
    return [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:TTIOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

void testEncryption(void)
{
    // ---- low-level GCM round-trip ----
    {
        NSData *key = make32ByteKey(7);
        NSString *msg = @"the quick brown fox jumps over the lazy dog";
        NSData *plain = [msg dataUsingEncoding:NSUTF8StringEncoding];
        NSData *iv = nil, *tag = nil;
        NSError *err = nil;
        NSData *cipher =
            [TTIOEncryptionManager encryptData:plain withKey:key iv:&iv authTag:&tag error:&err];
        PASS(cipher != nil, "AES-256-GCM encrypt returns ciphertext");
        PASS(iv.length == 12, "GCM IV is 12 bytes");
        PASS(tag.length == 16, "GCM tag is 16 bytes");
        PASS(![cipher isEqualToData:plain], "ciphertext differs from plaintext");

        NSData *decrypted =
            [TTIOEncryptionManager decryptData:cipher withKey:key iv:iv authTag:tag error:&err];
        PASS([decrypted isEqualToData:plain], "decrypt with correct key returns plaintext");

        NSData *wrongKey = make32ByteKey(99);
        NSError *err2 = nil;
        NSData *bogus =
            [TTIOEncryptionManager decryptData:cipher withKey:wrongKey iv:iv authTag:tag error:&err2];
        PASS(bogus == nil, "decrypt with wrong key returns nil");
        PASS(err2 != nil, "wrong-key decrypt populates NSError");

        NSMutableData *tampered = [cipher mutableCopy];
        ((uint8_t *)tampered.mutableBytes)[0] ^= 0xff;
        NSError *err3 = nil;
        NSData *tres =
            [TTIOEncryptionManager decryptData:tampered withKey:key iv:iv authTag:tag error:&err3];
        PASS(tres == nil, "tampered ciphertext fails authentication");
        PASS(err3 != nil, "tampered ciphertext populates NSError");
    }

    // ---- selective intensity-channel encryption on a real run ----
    NSString *path = encPath(@"run");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    {
        TTIOAcquisitionRun *run = buildSmallRun();
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        PASS([run writeToGroup:[f rootGroup] name:@"run_0001" error:&err], "run writes");
        [f close];
    }

    PASS(![TTIOEncryptionManager isIntensityChannelEncryptedInRun:@"run_0001"
                                                       atFilePath:path],
         "fresh run is not encrypted");

    // Capture original plaintext intensity for byte-exact verification later.
    NSData *originalIntensity = nil;
    {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Group *runG = [[f rootGroup] openGroupNamed:@"run_0001" error:&err];
        TTIOHDF5Group *ch = [runG openGroupNamed:@"signal_channels" error:&err];
        TTIOHDF5Dataset *ds = [ch openDatasetNamed:@"intensity_values" error:&err];
        originalIntensity = [ds readDataWithError:&err];
        PASS(originalIntensity.length == 5 * 8 * sizeof(double),
             "captured original intensity (40 doubles)");
        [f close];
    }

    // Encrypt the intensity channel.
    NSData *key = make32ByteKey(123);
    PASS([TTIOEncryptionManager encryptIntensityChannelInRun:@"run_0001"
                                                  atFilePath:path
                                                     withKey:key
                                                       error:&err],
         "encrypt intensity channel succeeds");
    PASS([TTIOEncryptionManager isIntensityChannelEncryptedInRun:@"run_0001"
                                                      atFilePath:path],
         "channel is now reported as encrypted");

    // Verify mz_values are still readable without the key.
    {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Group *runG = [[f rootGroup] openGroupNamed:@"run_0001" error:&err];
        TTIOHDF5Group *ch = [runG openGroupNamed:@"signal_channels" error:&err];
        TTIOHDF5Dataset *mzDS = [ch openDatasetNamed:@"mz_values" error:&err];
        PASS(mzDS != nil, "mz_values still openable post-encryption");
        NSData *mz = [mzDS readDataWithError:&err];
        PASS(mz.length == 5 * 8 * sizeof(double),
             "mz_values still readable as plaintext");

        // The spectrum_index group is untouched by encryption.
        PASS([runG hasChildNamed:@"spectrum_index"], "spectrum_index untouched by encryption");
        [f close];
    }

    // Decrypt with correct key → byte-exact match.
    {
        NSData *plain = [TTIOEncryptionManager decryptIntensityChannelInRun:@"run_0001"
                                                                 atFilePath:path
                                                                    withKey:key
                                                                      error:&err];
        PASS(plain != nil, "decrypt with correct key returns plaintext");
        PASS([plain isEqualToData:originalIntensity],
             "decrypted intensity is byte-exact match to original");
    }

    // Decrypt with wrong key → nil + populated error, no partial bytes.
    {
        NSData *wrong = make32ByteKey(200);
        NSError *e = nil;
        NSData *plain = [TTIOEncryptionManager decryptIntensityChannelInRun:@"run_0001"
                                                                 atFilePath:path
                                                                    withKey:wrong
                                                                      error:&e];
        PASS(plain == nil, "decrypt with wrong key returns nil");
        PASS(e != nil, "wrong-key decrypt populates NSError");
    }

    // ---- access policy round-trip independent of key management ----
    {
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:&err];
        TTIOAccessPolicy *policy =
            [[TTIOAccessPolicy alloc] initWithPolicy:@{
                @"version":  @1,
                @"subjects": @[ @"alice@lab", @"bob@lab" ],
                @"streams":  @[ @"run_0001/signal_channels/intensity_values_encrypted" ],
                @"key_id":   @"kms://demo/2026"
            }];
        PASS([policy writeToFile:f error:&err], "write access policy JSON to /protection/");
        [f close];
    }
    {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOAccessPolicy *back = [TTIOAccessPolicy readFromFile:f error:&err];
        PASS(back != nil, "access policy reads back without a key");
        PASS([back.policy[@"subjects"] containsObject:@"alice@lab"], "policy subjects preserved");
        PASS([back.policy[@"key_id"] isEqualToString:@"kms://demo/2026"],
             "policy key_id preserved");
        [f close];
    }

    unlink([path fileSystemRepresentation]);
}
