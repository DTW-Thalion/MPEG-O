#ifndef TTIO_ENCRYPTION_MANAGER_H
#define TTIO_ENCRYPTION_MANAGER_H

#import <Foundation/Foundation.h>

/* clang and gcc both support __attribute__((deprecated(msg))). The
 * cross-compiler guard that used to wrap this has been removed because
 * (a) every supported toolchain recognizes the attribute and (b)
 * autogsdoc has its own tokenizer and does not run the C preprocessor,
 * so the bare __attribute__((deprecated(...))) is parsed directly by
 * AGSParser.m — an intermediate macro produces an 'error parsing
 * method name' warning on every method it decorates. */

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Protection/TTIOEncryptionManager.h</p>
 *
 * <p>AES-256-GCM encryption helpers for selectively protecting
 * sensitive datasets inside a <code>.tio</code> file. Uses OpenSSL
 * EVP under the hood.</p>
 *
 * <p>Keys are 32 bytes (256-bit). IVs are 12 bytes (96-bit) and
 * are generated with <code>RAND_bytes</code> per encryption. Auth
 * tags are 16 bytes (128-bit). Wrong-key decrypts fail cleanly via
 * GCM tag mismatch with a populated <code>NSError</code>; no
 * plaintext is returned on failure.</p>
 *
 * <p>The intensity-channel methods operate on a closed
 * <code>.tio</code> file path so callers do not need to thread an
 * open <code>TTIOHDF5File</code> handle through. They open the
 * file in read-write mode, mutate the dataset structure, and close
 * it.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * Cross-language equivalents:
 *   Python: ttio.encryption
 *   Java:   global.thalion.ttio.protection.EncryptionManager
 */
@interface TTIOEncryptionManager : NSObject

#pragma mark - Low-level primitives

/** Encrypt `plaintext` with a 32-byte key. Returns ciphertext and writes
 *  IV + tag into the out-NSData parameters. */
+ (NSData *)encryptData:(NSData *)plaintext
                withKey:(NSData *)key
                     iv:(NSData **)outIv
                authTag:(NSData **)outTag
                  error:(NSError **)error;

/** Decrypt `ciphertext` using the given key, IV, and auth tag. Returns
 *  nil with a populated NSError on tag-mismatch (wrong key) or any
 *  other authenticated-decryption failure — never returns partial bytes. */
+ (NSData *)decryptData:(NSData *)ciphertext
                withKey:(NSData *)key
                     iv:(NSData *)iv
                authTag:(NSData *)authTag
                  error:(NSError **)error;

#pragma mark - Selective channel encryption

/**
 * Encrypt the `intensity_values` dataset of the named MS run inside
 * the `.tio` file at `path`. Replaces `signal_channels/intensity_values`
 * with `signal_channels/intensity_values_encrypted` (uint8 byte array)
 * plus three sibling 1-element datasets carrying the IV, auth tag, and
 * original element count, and one string attribute `intensity_algorithm`.
 *
 * `mz_values` and the spectrum index are left untouched, so unencrypted
 * tooling can still scan headers and m/z without the key.
 */
+ (BOOL)encryptIntensityChannelInRun:(NSString *)runName
                          atFilePath:(NSString *)path
                             withKey:(NSData *)key
                               error:(NSError **)error
    __attribute__((deprecated("Use -encryptWithKey_level_error_ on TTIOAcquisitionRun instead")));

/**
 * Decrypt the previously-encrypted intensity channel for the named run.
 * Returns the plaintext bytes (length = original_count * sizeof(double)).
 * The on-disk file is unchanged — decryption is read-only.
 */
+ (NSData *)decryptIntensityChannelInRun:(NSString *)runName
                              atFilePath:(NSString *)path
                                 withKey:(NSData *)key
                                   error:(NSError **)error
    __attribute__((deprecated("Use -decryptWithKey_error_ on TTIOAcquisitionRun instead")));

+ (BOOL)isIntensityChannelEncryptedInRun:(NSString *)runName
                              atFilePath:(NSString *)path
    __attribute__((deprecated("Query via TTIOAcquisitionRun.accessPolicy instead")));

/**
 * v1.1.1: persist-to-disk decrypt counterpart to
 * +encryptIntensityChannelInRun:atFilePath:withKey:error:.
 *
 * Opens the `.tio` file read-write, decrypts the named run's
 * `intensity_values_encrypted` dataset, writes plaintext back as a new
 * `intensity_values` Float64 dataset, deletes the encrypted siblings
 * (`intensity_values_encrypted`, `intensity_iv`, `intensity_tag`), and
 * removes the channel-level attrs `intensity_ciphertext_bytes`,
 * `intensity_original_count`, `intensity_algorithm`. The root
 * `@encrypted` attribute is left in place — callers that want a fully
 * unprotected file should use
 * `+[TTIOSpectralDataset decryptInPlaceAtPath:withKey:error:]`.
 *
 * Idempotent: returns YES with no error if the run is already plaintext.
 */
+ (BOOL)decryptIntensityChannelInRunInPlace:(NSString *)runName
                                 atFilePath:(NSString *)path
                                    withKey:(NSData *)key
                                      error:(NSError **)error;

@end

#endif
