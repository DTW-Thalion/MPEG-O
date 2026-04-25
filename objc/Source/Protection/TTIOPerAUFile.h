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

@end

NS_ASSUME_NONNULL_END

#endif
