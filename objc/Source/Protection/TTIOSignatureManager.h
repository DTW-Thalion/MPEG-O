#ifndef TTIO_SIGNATURE_MANAGER_H
#define TTIO_SIGNATURE_MANAGER_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Protection/TTIOSignatureManager.h</p>
 *
 * <p>HMAC-SHA256 signing and verification for TTI-O datasets.
 * Signatures are stored on the target dataset as a base64-encoded
 * string attribute named <code>@ttio_signature</code>. A file that
 * contains any signed datasets also carries
 * <code>opt_digital_signatures</code> in
 * <code>@ttio_features</code>.</p>
 *
 * <p>The signature covers the raw byte contents of the dataset
 * returned by <code>H5Dread</code>; for primitive numeric datasets
 * this is the platform little-endian layout, which is stable
 * across writer runs on a single platform and across the file
 * round-trip. For compound datasets this is the packed struct
 * representation; signature verification is intended to detect
 * in-place tampering on the same host, not cross-platform
 * authenticity attestation.</p>
 *
 * <p>Provenance-chain signing operates on the run's
 * <code>@provenance_json</code> attribute; the UTF-8 encoded JSON
 * string is HMAC'd and the signature stored as
 * <code>@provenance_signature</code> on the same run group.</p>
 *
 * <p>All methods require a 32-byte HMAC key. Shorter keys are
 * padded internally by OpenSSL; callers should use a strong
 * 256-bit secret.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * Cross-language equivalents:
 *   Python: ttio.signatures
 *   Java:   global.thalion.ttio.protection.SignatureManager
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
 * Sign a dataset with an explicit cipher-suite algorithm selector.
 *
 * For ``algorithm=@"hmac-sha256"``, ``key`` is the 32-byte HMAC
 * secret and the stored attribute is ``"v2:" + base64(mac)``. For
 * ``algorithm=@"ml-dsa-87"``, ``key`` is the 4896-byte ML-DSA-87
 * signing <b>private</b> key and the stored attribute is
 * ``"v3:" + base64(signature)``; the enclosing file gains the
 * ``opt_pqc_preview`` feature flag.
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
 */
+ (BOOL)verifyDataset:(NSString *)datasetPath
               inFile:(NSString *)filePath
              withKey:(NSData *)key
            algorithm:(NSString *)algorithm
                error:(NSError **)error;

#pragma mark - Genomic run-level convenience

/** Sign every signal channel + every genomic_index column under one
 *  genomic run with a single call.
 *
 *  Walks ``/study/genomic_runs/<runName>/signal_channels/{sequences,
 *  qualities}`` and ``/study/genomic_runs/<runName>/genomic_index/
 *  {offsets, lengths, positions, mapping_qualities, flags,
 *  chromosomes}`` and signs each existing dataset individually with
 *  HMAC-SHA256. The ``chromosomes`` compound is included alongside
 *  the atomic columns — the canonical-bytes reader serialises
 *  VL_STRING compound fields as ``u32_le(length) || utf-8_bytes``
 *  so the chromosome signature matches Python.
 *
 *  Returns a dictionary mapping each signed sub-path
 *  (e.g. ``"signal_channels/sequences"``,
 *  ``"genomic_index/positions"``) to the prefixed signature stored
 *  on that dataset's ``@ttio_signature`` attribute. Datasets that
 *  don't exist on disk (e.g. encrypted files where signal channels
 *  have been replaced by ``*_segments`` compounds) are silently
 *  skipped.
 */
+ (NSDictionary<NSString *, NSString *> *)
    signGenomicRun:(NSString *)runName
            inFile:(NSString *)filePath
           withKey:(NSData *)hmacKey
             error:(NSError **)error;

/** Verify every dataset that ``signGenomicRun:`` would sign.
 *
 *  Returns YES iff every present, signed dataset verifies under the
 *  key. Datasets that don't exist on disk are skipped. A present
 *  dataset that has no ``@ttio_signature`` (i.e. wasn't signed) is
 *  treated as a verification failure — a partial-signature run is
 *  not a fully-signed run.
 */
+ (BOOL)verifyGenomicRun:(NSString *)runName
                  inFile:(NSString *)filePath
                 withKey:(NSData *)hmacKey
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
