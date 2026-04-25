#ifndef TTIO_SIGNATURE_MANAGER_H
#define TTIO_SIGNATURE_MANAGER_H

#import <Foundation/Foundation.h>

/**
 * HMAC-SHA256 signing and verification for TTI-O datasets. Signatures
 * are stored on the target HDF5 dataset as a base64-encoded string
 * attribute named @ttio_signature. A file that contains any signed
 * datasets also carries opt_digital_signatures in @ttio_features.
 *
 * The signature covers the raw byte contents of the dataset returned
 * by H5Dread; for primitive numeric datasets this is the platform
 * little-endian layout, which is stable across writer runs on a
 * single platform and across the file round-trip. For compound
 * datasets this is the packed struct representation (warning: not
 * portable across platforms with different struct padding —
 * signature verification is intended to detect in-place tampering on
 * the same host, not cross-platform authenticity attestation).
 *
 * Provenance-chain signing operates on the run's @provenance_json
 * attribute introduced in Milestone 10; the UTF-8 encoded JSON string
 * is HMAC'd and the signature stored as @provenance_signature on the
 * same run group.
 *
 * All methods require a 32-byte HMAC key. Shorter keys are padded
 * internally by OpenSSL; callers should use a strong 256-bit secret.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.signatures
 *   Java:   com.dtwthalion.tio.protection.SignatureManager
 */
@interface TTIOSignatureManager : NSObject

#pragma mark - Low-level primitive

/** Compute an HMAC-SHA256 of `data` with `key`. Returns the raw 32
 *  byte digest. Never returns nil for a well-formed input. */
+ (NSData *)hmacSHA256OfData:(NSData *)data withKey:(NSData *)key;

#pragma mark - Dataset signing

/** Sign the dataset at `datasetPath` (HDF5 path, e.g.
 *  "/study/ms_runs/run_0001/signal_channels/intensity_values") inside
 *  the .tio file at `filePath`. Stores the HMAC as a base64 string
 *  attribute `@ttio_signature` on that dataset and writes
 *  `opt_digital_signatures` into the root feature flags if not
 *  already present. */
+ (BOOL)signDataset:(NSString *)datasetPath
             inFile:(NSString *)filePath
            withKey:(NSData *)hmacKey
              error:(NSError **)error;

/** Recompute the HMAC of the dataset bytes and compare to the stored
 *  `@ttio_signature` attribute. Returns YES if they match. On
 *  mismatch returns NO with a descriptive NSError in the TTIOError
 *  domain. A missing attribute returns NO with
 *  TTIOErrorAttributeRead — use TTIOVerifier for the three-state
 *  view. */
+ (BOOL)verifyDataset:(NSString *)datasetPath
               inFile:(NSString *)filePath
              withKey:(NSData *)hmacKey
                error:(NSError **)error;

/**
 * Sign a dataset with an explicit cipher-suite algorithm selector
 * (v0.8 M49.1).
 *
 * For ``algorithm=@"hmac-sha256"``, ``key`` is the 32-byte HMAC
 * secret and the stored attribute is ``"v2:" + base64(mac)``. For
 * ``algorithm=@"ml-dsa-87"``, ``key`` is the 4896-byte ML-DSA-87
 * signing <b>private</b> key and the stored attribute is
 * ``"v3:" + base64(signature)``; the enclosing file gains the
 * ``opt_pqc_preview`` feature flag.
 *
 * @since 0.8
 */
+ (BOOL)signDataset:(NSString *)datasetPath
             inFile:(NSString *)filePath
            withKey:(NSData *)key
           algorithm:(NSString *)algorithm
              error:(NSError **)error;

/**
 * Verify a signed dataset with an explicit cipher-suite algorithm
 * selector. ``algorithm`` must match the stored prefix — a ``v3:``
 * attribute rejects ``algorithm=@"hmac-sha256"`` and vice-versa.
 *
 * For ``algorithm=@"ml-dsa-87"``, ``key`` is the 2592-byte
 * verification public key.
 *
 * @since 0.8
 */
+ (BOOL)verifyDataset:(NSString *)datasetPath
               inFile:(NSString *)filePath
              withKey:(NSData *)key
            algorithm:(NSString *)algorithm
                error:(NSError **)error;

#pragma mark - Provenance signing

/** Sign the `@provenance_json` attribute on the given run group.
 *  `runPath` is the HDF5 group path, e.g.
 *  "/study/ms_runs/run_0001". Stores the HMAC under
 *  `@provenance_signature` on that group. */
+ (BOOL)signProvenanceInRun:(NSString *)runPath
                     inFile:(NSString *)filePath
                    withKey:(NSData *)hmacKey
                      error:(NSError **)error;

/** Recompute the HMAC over the provenance JSON and compare. */
+ (BOOL)verifyProvenanceInRun:(NSString *)runPath
                       inFile:(NSString *)filePath
                      withKey:(NSData *)hmacKey
                        error:(NSError **)error;

@end

#endif
