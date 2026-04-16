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
}
