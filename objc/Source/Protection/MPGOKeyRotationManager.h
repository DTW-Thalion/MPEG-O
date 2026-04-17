#ifndef MPGO_KEY_ROTATION_MANAGER_H
#define MPGO_KEY_ROTATION_MANAGER_H

#import <Foundation/Foundation.h>

@class MPGOHDF5File;

/**
 * Milestone 25 — envelope encryption + key rotation.
 *
 * Envelope model: a Data Encryption Key (DEK, 32 bytes) encrypts the
 * signal data. A Key Encryption Key (KEK, 32 bytes) wraps the DEK with
 * AES-256-GCM. Rotation re-wraps the DEK under a new KEK without
 * touching any signal dataset, so it's O(1) in file size.
 *
 * On-disk layout (additive to /protection/, present iff ``opt_key_rotation``):
 *   /protection/key_info/
 *     @kek_id         (string) — caller-supplied KEK identifier
 *     @kek_algorithm  (string) — always "aes-256-gcm" in v0.4
 *     @wrapped_at     (string) — ISO-8601 timestamp of the most recent wrap
 *     dek_wrapped     (uint8[60]) — 32 cipher + 12 IV + 16 tag
 *     key_history/    (subgroup)
 *       @count        (int64)  — number of prior (timestamp,kek_id) entries
 *       entries       (compound dataset: timestamp string, kek_id string,
 *                      kek_algorithm string)
 *
 * Usage:
 *   MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
 *   MPGOKeyRotationManager *mgr = [MPGOKeyRotationManager managerWithFile:f];
 *   NSData *dek = [mgr enableEnvelopeEncryptionWithKEK:kek1
 *                                                kekId:@"kek-1"
 *                                                error:&err];
 *   // ... write data using `dek` as the per-dataset AES-GCM key ...
 *   // Later, rotate:
 *   [mgr rotateToKEK:kek2 kekId:@"kek-2" oldKEK:kek1 error:&err];
 *   // Later still, read:
 *   NSData *recovered = [mgr unwrapDEKWithKEK:kek2 error:&err];
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.key_rotation
 *   Java:   com.dtwthalion.mpgo.protection.KeyRotationManager
 */
@interface MPGOKeyRotationManager : NSObject

/** Create a manager bound to an open HDF5 file. */
+ (instancetype)managerWithFile:(MPGOHDF5File *)file;

/**
 * Generate a fresh 32-byte DEK, wrap it under ``kek``, and persist the
 * wrapped key + metadata under ``/protection/key_info/``. Returns the
 * plaintext DEK for the caller to use when encrypting signal datasets,
 * or nil on failure. Overwrites any existing key_info contents, so
 * callers must treat this as a one-shot initializer.
 */
- (NSData *)enableEnvelopeEncryptionWithKEK:(NSData *)kek
                                      kekId:(NSString *)kekId
                                      error:(NSError **)error;

/**
 * Rotate the wrapping key. Unwraps the current DEK with ``oldKEK``,
 * re-wraps with ``newKEK``, updates ``@kek_id`` / ``@wrapped_at``, and
 * appends the previous (timestamp, kek_id, kek_algorithm) entry to
 * ``/protection/key_info/key_history/entries``. Signal datasets are not
 * touched. Returns NO on failure (wrong oldKEK, auth tag mismatch,
 * missing key_info, etc.).
 */
- (BOOL)rotateToKEK:(NSData *)newKEK
              kekId:(NSString *)newKEKId
             oldKEK:(NSData *)oldKEK
              error:(NSError **)error;

/**
 * Unwrap the DEK using the current wrapping key. Returns nil if the
 * KEK does not authenticate the wrapped blob (wrong key, tampered
 * file, or missing key_info group).
 */
- (NSData *)unwrapDEKWithKEK:(NSData *)kek error:(NSError **)error;

/** Returns YES if ``/protection/key_info/dek_wrapped`` is present. */
- (BOOL)hasEnvelopeEncryption;

/**
 * Returns the list of historical KEK rotations as
 * ``NSArray<NSDictionary *>`` where each dict has keys
 * ``timestamp``, ``kek_id``, ``kek_algorithm``. The newest entry is
 * last; the currently-active KEK is *not* in history (it's live on
 * the group attributes).
 */
- (NSArray<NSDictionary *> *)keyHistory;

@end

#endif
