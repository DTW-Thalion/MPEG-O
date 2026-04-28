/*
 * TTIOPerAUFile — v1.0 file-level per-AU encryption orchestrator.
 *
 * Reads plaintext <channel>_values datasets from an TTI-O file,
 * encrypts each spectrum independently with TTIOPerAUEncryption,
 * and rewrites the file's signal_channels groups with the
 * <channel>_segments compound layout from docs/format-spec.md §9.1.
 * Routes through the TTIOStorageProvider / TTIOStorageGroup
 * abstraction so any backend that supports VL_BYTES compound
 * fields (HDF5 today; Memory today; SQLite / Zarr after their
 * compound paths grow base64 transport) works.
 *
 * Cross-language equivalents:
 *   Python: ttio.encryption_per_au.encrypt_per_au/decrypt_per_au
 *   Java:   global.thalion.ttio.protection.PerAUFile
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_PER_AU_FILE_H
#define TTIO_PER_AU_FILE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTIOPerAUFile : NSObject

/** Encrypt ``path`` in place with per-AU AES-256-GCM.
 *
 *  For each MS run, reads plaintext <channel>_values, slices by the
 *  run's spectrum_index/{offsets,lengths}, encrypts each row with a
 *  fresh IV + AAD = dataset_id || au_sequence || channel_name, and
 *  writes a <channel>_segments compound dataset. The plaintext
 *  <channel>_values dataset is deleted.
 *
 *  When ``encryptHeaders`` is YES, also encrypts the six semantic
 *  index arrays (retention_times, ms_levels, polarities,
 *  precursor_mzs, precursor_charges, base_peak_intensities) into
 *  spectrum_index/au_header_segments and deletes the plaintext
 *  arrays. Offsets + lengths remain plaintext (structural framing,
 *  not semantic PHI).
 *
 *  Sets the opt_per_au_encryption feature flag on the root group
 *  (and opt_encrypted_au_headers when header encryption is used).
 *
 *  ``providerName`` may be nil (scheme-based routing via
 *  TTIOProviderRegistry); passing "hdf5" forces the HDF5 provider.
 */
+ (BOOL)encryptFilePath:(NSString *)path
                     key:(NSData *)key
         encryptHeaders:(BOOL)encryptHeaders
            providerName:(nullable NSString *)providerName
                   error:(NSError * _Nullable *)error;

/** Read-only decrypt: return ``{run_name: {channel_name: NSData
 *  float64 LE}}`` for a per-AU-encrypted file. When
 *  opt_encrypted_au_headers is set, the run map also carries
 *  ``__au_headers__`` as an NSArray<TTIOAUHeaderPlaintext *>.
 */
+ (nullable NSDictionary<NSString *, NSDictionary *> *)
    decryptFilePath:(NSString *)path
                key:(NSData *)key
       providerName:(nullable NSString *)providerName
              error:(NSError * _Nullable *)error;

#pragma mark - M90.4 — region-based per-AU encryption

/** Encrypt genomic signal channels with a per-chromosome key map.
 *
 *  Reads whose chromosome appears in ``keyMap`` are AES-256-GCM
 *  encrypted with the corresponding 32-byte key. Reads on chromosomes
 *  NOT in ``keyMap`` are stored as "clear segments" — the same
 *  ``<channel>_segments`` compound is reused, but with a length-0 IV
 *  / length-0 tag and the raw plaintext bytes stored in the
 *  ``ciphertext`` slot. The decoder branches on ``len(seg.iv)``, so
 *  old M90.1 files (every IV is exactly 12 bytes) decode unchanged
 *  under the new code path.
 *
 *  MS runs are NOT touched — chromosome is a genomic concept. Use
 *  ``encryptFilePath:`` for MS encryption.
 *
 *  Sets the ``opt_per_au_encryption`` and
 *  ``opt_region_keyed_encryption`` feature flags on the root group.
 *  The per-channel ``<channel>_algorithm`` attribute is set to
 *  ``"aes-256-gcm-by-region"``.
 */
+ (BOOL)encryptFilePathByRegion:(NSString *)path
                          keyMap:(NSDictionary<NSString *, NSData *> *)keyMap
                    providerName:(nullable NSString *)providerName
                           error:(NSError * _Nullable *)error;

/** Decrypt a region-encrypted file using a per-chromosome key map.
 *
 *  Caller may supply only a subset of the keys used at encryption
 *  time. Clear segments (length-0 IV) decode without any key.
 *  Encrypted segments whose chromosome key isn't in ``keyMap``
 *  cause the call to fail (no key available).
 *
 *  Returns ``{run_name: {channel_name: NSData uint8}}`` like
 *  ``decryptFilePath:`` (genomic dtype is uint8, one ASCII byte per
 *  base). MS runs are not part of region-keyed encryption; this
 *  helper does not touch them.
 */
+ (nullable NSDictionary<NSString *, NSDictionary *> *)
    decryptFilePathByRegion:(NSString *)path
                      keyMap:(NSDictionary<NSString *, NSData *> *)keyMap
                providerName:(nullable NSString *)providerName
                       error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
