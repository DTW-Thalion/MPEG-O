#ifndef TTIO_KEY_ROTATION_MANAGER_H
#define TTIO_KEY_ROTATION_MANAGER_H

#import <Foundation/Foundation.h>

@class TTIOHDF5File;

/**
 * <heading>TTIOKeyRotationManager</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em>
 * Protection/TTIOKeyRotationManager.h</p>
 *
 * <p>Envelope encryption + key rotation. A Data Encryption Key
 * (DEK, 32 bytes) encrypts the signal data. A Key Encryption Key
 * (KEK, 32 bytes) wraps the DEK with AES-256-GCM. Rotation
 * re-wraps the DEK under a new KEK without touching any signal
 * dataset, so it is O(1) in file size.</p>
 *
 * <p>On-disk layout (additive to <code>/protection/</code>, present
 * iff <code>opt_key_rotation</code>):</p>
 *
 * <pre>
 *   /protection/key_info/
 *     @kek_id         (string) — caller-supplied KEK identifier
 *     @kek_algorithm  (string) — algorithm identifier (e.g. "aes-256-gcm")
 *     @wrapped_at     (string) — ISO-8601 timestamp of the most recent wrap
 *     dek_wrapped     (uint8[60]) — 32 cipher + 12 IV + 16 tag
 *     key_history/    (subgroup)
 *       @count        (int64)  — number of prior (timestamp, kek_id) entries
 *       entries       (compound dataset: timestamp string, kek_id string,
 *                      kek_algorithm string)
 * </pre>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.key_rotation_manager.KeyRotationManager</code><br/>
 * Java:
 * <code>global.thalion.ttio.protection.KeyRotationManager</code></p>
 *
 * Usage:
 *   TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&amp;err];
 *   TTIOKeyRotationManager *mgr = [TTIOKeyRotationManager managerWithFile:f];
 *   NSData *dek = [mgr enableEnvelopeEncryptionWithKEK:kek1
 *                                                kekId:@"kek-1"
 *                                                error:&amp;err];
 *   // ... write data using `dek` as the per-dataset AES-GCM key ...
 *   // Later, rotate:
 *   [mgr rotateToKEK:kek2 kekId:@"kek-2" oldKEK:kek1 error:&amp;err];
 *   // Later still, read:
 *   NSData *recovered = [mgr unwrapDEKWithKEK:kek2 error:&amp;err];
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.key_rotation
 *   Java:   global.thalion.ttio.protection.KeyRotationManager
 */
@interface TTIOKeyRotationManager : NSObject

/** Create a manager bound to an open HDF5 file. */
+ (instancetype)managerWithFile:(TTIOHDF5File *)file;

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

/**
 * Low-level wrap primitive with explicit version selection.
 *
 * Default callers should prefer
 * ``-enableEnvelopeEncryptionWithKEK:kekId:error:`` which always writes
 * the canonical versioned blob. This method is exposed for regression
 * fixtures and cross-version backward-compat tests: pass ``legacyV1=YES``
 * to emit the 60-byte legacy layout readable by older readers.
 */
- (NSData *)wrapDEK:(NSData *)dek
            withKEK:(NSData *)kek
            legacyV1:(BOOL)legacyV1
              error:(NSError **)error;

/**
 * Envelope encryption with an algorithm selector.
 *
 * For ``algorithm="aes-256-gcm"`` (default), ``kek`` is a 32-byte
 * symmetric key. For ``algorithm="ml-kem-1024"``, ``kek`` is the
 * 1568-byte ML-KEM encapsulation <b>public</b> key, and the resulting
 * file gets the ``opt_pqc_preview`` feature flag on its root group.
 */
- (NSData *)enableEnvelopeEncryptionWithKEK:(NSData *)kek
                                      kekId:(NSString *)kekId
                                   algorithm:(NSString *)algorithm
                                       error:(NSError **)error;

/**
 * Unwrap the DEK under the given algorithm. For
 * ``algorithm="ml-kem-1024"``, ``kek`` is the 3168-byte decapsulation
 * <b>private</b> key.
 *
 * @since 0.8
 */
- (NSData *)unwrapDEKWithKEK:(NSData *)kek
                    algorithm:(NSString *)algorithm
                        error:(NSError **)error;

/**
 * Rotate the wrapping key with optional algorithm migration
 * (AES-256-GCM ⇄ ML-KEM-1024). ``oldAlgorithm`` matches the algorithm
 * used to write the file; pass a different ``newAlgorithm`` to migrate.
 *
 * @since 0.8
 */
- (BOOL)rotateToKEK:(NSData *)newKEK
              kekId:(NSString *)newKEKId
             oldKEK:(NSData *)oldKEK
        oldAlgorithm:(NSString *)oldAlgorithm
        newAlgorithm:(NSString *)newAlgorithm
              error:(NSError **)error;

/** Returns YES if ``/protection/key_info/dek_wrapped`` is present. */
- (BOOL)hasEnvelopeEncryption;

/**
 * Returns the list of historical KEK rotations as
 * ``NSArray&lt;NSDictionary *&gt;`` where each dict has keys
 * ``timestamp``, ``kek_id``, ``kek_algorithm``. The newest entry is
 * last; the currently-active KEK is *not* in history (it's live on
 * the group attributes).
 */
- (NSArray<NSDictionary *> *)keyHistory;

@end

#endif
