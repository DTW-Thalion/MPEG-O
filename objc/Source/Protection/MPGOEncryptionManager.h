#ifndef MPGO_ENCRYPTION_MANAGER_H
#define MPGO_ENCRYPTION_MANAGER_H

#import <Foundation/Foundation.h>

/**
 * AES-256-GCM encryption helpers for selectively protecting sensitive
 * datasets inside an `.mpgo` file. Uses OpenSSL EVP under the hood.
 *
 * Keys are 32 bytes (256-bit). IVs are 12 bytes (96-bit) and are
 * generated with RAND_bytes per encryption. Auth tags are 16 bytes
 * (128-bit). Wrong-key decrypts fail cleanly via GCM tag mismatch with
 * a populated NSError; no plaintext is returned on failure.
 *
 * The intensity-channel methods operate on a closed `.mpgo` file path
 * so callers don't need to thread an open MPGOHDF5File handle through.
 * They open the file in read-write mode, mutate the dataset structure,
 * and close it.
 */
@interface MPGOEncryptionManager : NSObject

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
 * the `.mpgo` file at `path`. Replaces `signal_channels/intensity_values`
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
                               error:(NSError **)error;

/**
 * Decrypt the previously-encrypted intensity channel for the named run.
 * Returns the plaintext bytes (length = original_count * sizeof(double)).
 * The on-disk file is unchanged — decryption is read-only.
 */
+ (NSData *)decryptIntensityChannelInRun:(NSString *)runName
                              atFilePath:(NSString *)path
                                 withKey:(NSData *)key
                                   error:(NSError **)error;

+ (BOOL)isIntensityChannelEncryptedInRun:(NSString *)runName
                              atFilePath:(NSString *)path;

@end

#endif
