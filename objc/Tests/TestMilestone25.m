// Milestone 25: envelope encryption + key rotation.
//
// Verifies:
//   * enableEnvelopeEncryptionWithKEK: persists /protection/key_info with
//     a wrapped 60-byte DEK blob, KEK id, algorithm, and timestamp.
//   * unwrapDEKWithKEK: recovers the DEK with the right KEK; fails with
//     the wrong KEK.
//   * rotateToKEK: re-wraps the DEK under a new KEK in O(1), updates
//     the live attrs, and appends a history entry. After rotation the
//     old KEK no longer unwraps.
//   * Rotation cost: a single rotate call completes in < 100 ms.
//   * Feature flag string `opt_key_rotation` is present on the manager.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOFeatureFlags.h"
#import "Protection/MPGOKeyRotationManager.h"
#import <unistd.h>

static NSString *m25TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m25_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static NSData *m25MakeKey(uint8_t seed)
{
    uint8_t buf[32];
    for (int i = 0; i < 32; i++) buf[i] = (uint8_t)(seed ^ (i * 7 + 13));
    return [NSData dataWithBytes:buf length:32];
}

void testMilestone25(void)
{
    // ---- feature flag string is available ----
    PASS([[MPGOFeatureFlags featureKeyRotation] isEqualToString:@"opt_key_rotation"],
         "M25: featureKeyRotation constant");

    NSString *path = m25TempPath(@"envelope");
    unlink([path fileSystemRepresentation]);

    NSData *kek1 = m25MakeKey(0xA1);
    NSData *kek2 = m25MakeKey(0xB2);
    NSData *kek3 = m25MakeKey(0xC3);

    // ---- enable envelope encryption ----
    NSData *dek1 = nil;
    {
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS(f != nil, "M25: create file");
        MPGOKeyRotationManager *mgr = [MPGOKeyRotationManager managerWithFile:f];
        PASS(![mgr hasEnvelopeEncryption],
             "M25: fresh file reports no envelope encryption");

        dek1 = [mgr enableEnvelopeEncryptionWithKEK:kek1 kekId:@"kek-1" error:&err];
        PASS(dek1 != nil, "M25: enableEnvelopeEncryption returns DEK");
        PASS(dek1.length == 32, "M25: DEK is 32 bytes");
        PASS([mgr hasEnvelopeEncryption],
             "M25: hasEnvelopeEncryption true after enable");

        NSData *dekRead = [mgr unwrapDEKWithKEK:kek1 error:&err];
        PASS(dekRead != nil && [dekRead isEqualToData:dek1],
             "M25: unwrap with KEK-1 round-trips the DEK");

        NSError *wrongErr = nil;
        NSData *dekWrong = [mgr unwrapDEKWithKEK:kek2 error:&wrongErr];
        PASS(dekWrong == nil, "M25: unwrap with wrong KEK fails");

        [f close];
    }

    // ---- reopen, rotate KEK-1 -> KEK-2 ----
    {
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File openAtPath:path error:&err];
        PASS(f != nil, "M25: reopen file for rotation");
        MPGOKeyRotationManager *mgr = [MPGOKeyRotationManager managerWithFile:f];

        NSDate *t0 = [NSDate date];
        BOOL ok = [mgr rotateToKEK:kek2 kekId:@"kek-2" oldKEK:kek1 error:&err];
        NSTimeInterval elapsed = -[t0 timeIntervalSinceNow];
        PASS(ok == YES, "M25: rotateToKEK with correct old KEK succeeds");
        PASS(elapsed < 0.100, "M25: rotation completes in < 100 ms");

        NSData *dekAfter = [mgr unwrapDEKWithKEK:kek2 error:&err];
        PASS(dekAfter != nil && [dekAfter isEqualToData:dek1],
             "M25: unwrap with KEK-2 returns the original DEK (data not re-encrypted)");

        NSError *failErr = nil;
        NSData *dekOld = [mgr unwrapDEKWithKEK:kek1 error:&failErr];
        PASS(dekOld == nil, "M25: KEK-1 no longer unwraps after rotation");

        NSArray *history = [mgr keyHistory];
        PASS(history.count == 1, "M25: history holds one entry after first rotation");
        PASS([history[0][@"kek_id"] isEqualToString:@"kek-1"],
             "M25: history entry tracks previous KEK id");
        PASS([history[0][@"kek_algorithm"] isEqualToString:@"aes-256-gcm"],
             "M25: history entry tracks algorithm");

        [f close];
    }

    // ---- second rotation: KEK-2 -> KEK-3 ----
    {
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File openAtPath:path error:&err];
        MPGOKeyRotationManager *mgr = [MPGOKeyRotationManager managerWithFile:f];

        BOOL ok = [mgr rotateToKEK:kek3 kekId:@"kek-3" oldKEK:kek2 error:&err];
        PASS(ok == YES, "M25: second rotation succeeds");
        NSArray *history = [mgr keyHistory];
        PASS(history.count == 2, "M25: history grows to two entries");
        PASS([history[1][@"kek_id"] isEqualToString:@"kek-2"],
             "M25: second history entry is the previous (kek-2)");

        NSData *finalDek = [mgr unwrapDEKWithKEK:kek3 error:&err];
        PASS(finalDek != nil && [finalDek isEqualToData:dek1],
             "M25: KEK-3 still recovers the original DEK after two rotations");

        [f close];
    }

    unlink([path fileSystemRepresentation]);

    // ---- M47: v1.2 wrapped-key blob is the default ----
    NSString *v12Path = m25TempPath(@"v12");
    unlink([v12Path fileSystemRepresentation]);
    {
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:v12Path error:&err];
        MPGOKeyRotationManager *mgr = [MPGOKeyRotationManager managerWithFile:f];
        NSData *dek = [mgr enableEnvelopeEncryptionWithKEK:kek1
                                                      kekId:@"kek-v12"
                                                      error:&err];
        PASS(dek != nil, "M47: enableEnvelopeEncryption produces DEK");
        [f close];

        // Re-open and inspect the raw dek_wrapped bytes + the new
        // @dek_wrapped_bytes attribute that records the actual length.
        f = [MPGOHDF5File openReadOnlyAtPath:v12Path error:&err];
        MPGOHDF5Group *root = [f rootGroup];
        MPGOHDF5Group *prot = [root openGroupNamed:@"protection" error:&err];
        MPGOHDF5Group *ki   = [prot openGroupNamed:@"key_info" error:&err];
        MPGOHDF5Dataset *ds = [ki openDatasetNamed:@"dek_wrapped" error:&err];
        NSData *rawAligned = [ds readDataWithError:&err];
        PASS(rawAligned != nil, "M47: raw dek_wrapped readable");

        BOOL haveLenAttr = NO;
        int64_t declared = [ki integerAttributeNamed:@"dek_wrapped_bytes"
                                                 exists:&haveLenAttr
                                                  error:NULL];
        PASS(haveLenAttr, "M47: @dek_wrapped_bytes attribute present");
        PASS(declared == 71,
             "M47: v1.2 AES-GCM blob is 71 bytes (got %lld)", declared);
        // Magic 'MW' + version 0x02 + algorithm_id 0x0000.
        const uint8_t *raw = rawAligned.bytes;
        PASS(raw[0] == 'M' && raw[1] == 'W' && raw[2] == 0x02,
             "M47: v1.2 blob magic + version header");
        PASS(raw[3] == 0x00 && raw[4] == 0x00,
             "M47: algorithm_id = 0x0000 (AES-256-GCM)");

        [f close];
    }
    unlink([v12Path fileSystemRepresentation]);

    // ---- M47 Binding Decision 38: v1.1 (60-byte) legacy readable ----
    NSString *v11Path = m25TempPath(@"v11-legacy");
    unlink([v11Path fileSystemRepresentation]);
    {
        // Hand-craft a v1.1 file: 60-byte blob, no @dek_wrapped_bytes.
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:v11Path error:&err];
        MPGOKeyRotationManager *mgr = [MPGOKeyRotationManager managerWithFile:f];

        NSData *dek = m25MakeKey(0xD4);
        NSData *v11Blob = [mgr wrapDEK:dek
                                 withKEK:kek1
                                 legacyV1:YES
                                   error:&err];
        PASS(v11Blob.length == 60,
             "M47: legacyV1 wrap produces 60-byte blob");

        MPGOHDF5Group *root = [f rootGroup];
        MPGOHDF5Group *prot = [root createGroupNamed:@"protection" error:&err];
        MPGOHDF5Group *ki   = [prot createGroupNamed:@"key_info" error:&err];
        // Write via the public path so @dek_wrapped_bytes would be
        // included — then delete the attribute so this mimics a real
        // pre-v0.7 file exactly.
        MPGOHDF5Dataset *ds = [ki createDatasetNamed:@"dek_wrapped"
                                             precision:MPGOPrecisionInt32
                                                length:15
                                             chunkSize:0
                                           compression:MPGOCompressionNone
                                      compressionLevel:0
                                                 error:&err];
        [ds writeData:v11Blob error:&err];
        [ki setStringAttribute:@"kek_id" value:@"kek-v11" error:&err];
        [ki setStringAttribute:@"kek_algorithm" value:@"aes-256-gcm" error:&err];
        [f close];

        // Unwrap via v0.7 code — must succeed.
        f = [MPGOHDF5File openAtPath:v11Path error:&err];
        mgr = [MPGOKeyRotationManager managerWithFile:f];
        NSData *recovered = [mgr unwrapDEKWithKEK:kek1 error:&err];
        PASS(recovered != nil && [recovered isEqualToData:dek],
             "M47: v1.1 legacy 60-byte blob unwraps under v0.7 code");
        [f close];
    }
    unlink([v11Path fileSystemRepresentation]);
}
