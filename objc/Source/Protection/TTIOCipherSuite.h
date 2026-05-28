/*
 * TTIOCipherSuite.h
 *
 * Cipher-suite catalogue and algorithm-dispatched parameter
 * helpers. The encryption / signing / key-wrap APIs accept an
 * `algorithm:` parameter backed by this catalogue. Adding a new
 * algorithm is a source-code change to the static allow-list, not
 * a plugin-registration call.
 *
 * Cross-language equivalents:
 *   Python: ttio.cipher_suite
 *   Java:   global.thalion.ttio.protection.CipherSuite
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_CIPHER_SUITE_H
#define TTIO_CIPHER_SUITE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TTIOCipherCategory) {
    TTIOCipherCategoryAEAD      = 0,
    TTIOCipherCategoryKEM       = 1,
    TTIOCipherCategoryMAC       = 2,
    TTIOCipherCategorySignature = 3,
    TTIOCipherCategoryHash      = 4,
    TTIOCipherCategoryXOF       = 5,
};

typedef NS_ENUM(NSInteger, TTIOCipherStatus) {
    TTIOCipherStatusActive   = 0,
    TTIOCipherStatusReserved = 1,
};

@interface TTIOCipherSuite : NSObject

/**
 * Whether the named algorithm is supported (catalog entry with Active status).
 *
 * @param algorithm  Algorithm identifier (e.g. `@"AES-256-GCM"`,
 *                   `@"ML-KEM-1024"`).
 * @return YES iff the algorithm is in the catalog and currently active.
 */
+ (BOOL)isSupported:(NSString *)algorithm;

/**
 * Whether the named algorithm is registered (catalog entry, active or reserved).
 *
 * @param algorithm  Algorithm identifier.
 * @return YES iff the algorithm appears anywhere in the catalog
 *         (active or reserved-for-future status).
 */
+ (BOOL)isRegistered:(NSString *)algorithm;

/**
 * Return the cipher category for the named algorithm.
 *
 * For unknown algorithms returns `TTIOCipherCategoryAEAD` as a
 * fallback; callers that need to distinguish unknown from AEAD
 * should pre-gate with `+isRegistered:`.
 *
 * @param algorithm  Algorithm identifier.
 * @return Cipher category (AEAD / KEM / MAC / Signature / Hash / XOF).
 */
+ (TTIOCipherCategory)category:(NSString *)algorithm;

/**
 * Return the fixed key length in bytes for the named algorithm.
 *
 * Returns `-1` for variable-length keys (HMAC family). For KEM /
 * Signature algorithms returns the public-key length. Returns `0`
 * for unknown algorithms.
 *
 * @param algorithm  Algorithm identifier.
 * @return Key length in bytes, `-1` for variable, or `0` for unknown.
 */
+ (NSInteger)keyLength:(NSString *)algorithm;

/**
 * Return the public-key length in bytes for an asymmetric algorithm.
 *
 * Raises `NSInvalidArgumentException` for symmetric algorithms.
 *
 * @param algorithm  KEM or Signature algorithm identifier.
 * @return Public-key length in bytes.
 */
+ (NSInteger)publicKeySize:(NSString *)algorithm;

/**
 * Return the private-key length in bytes for an asymmetric algorithm.
 *
 * Raises `NSInvalidArgumentException` for symmetric algorithms.
 *
 * @param algorithm  KEM or Signature algorithm identifier.
 * @return Private-key length in bytes.
 */
+ (NSInteger)privateKeySize:(NSString *)algorithm;

/**
 * Return the nonce / IV length in bytes for the named algorithm.
 *
 * Zero for non-AEAD primitives (MAC, Hash, XOF).
 *
 * @param algorithm  Algorithm identifier.
 * @return Nonce length in bytes, or `0` if not applicable.
 */
+ (NSInteger)nonceLength:(NSString *)algorithm;

/**
 * Return the tag / signature length in bytes for the named algorithm.
 *
 * For AEAD ciphers this is the authentication-tag length; for
 * signature algorithms the signature length; for MACs the output
 * length.
 *
 * @param algorithm  Algorithm identifier.
 * @return Tag / signature length in bytes.
 */
+ (NSInteger)tagLength:(NSString *)algorithm;

/** Validate that ``key`` has the correct length for ``algorithm``.
 *  Returns NO and populates @c error on mismatch. Reserved or unknown
 *  algorithms return NO with an "algorithm not supported" error.
 *
 *  For asymmetric algorithms (KEM / Signature), this method returns
 *  NO with a directive pointing to -validatePublicKey: or
 *  -validatePrivateKey:. Symmetric-only by design. */
+ (BOOL)validateKey:(NSData *)key
          algorithm:(NSString *)algorithm
              error:(NSError **)error;

/**
 * Validate a public-key candidate against the asymmetric algorithm's
 * expected length.
 *
 * Symmetric algorithms return NO with an "asymmetric required"
 * error.
 *
 * @param key        Candidate public-key bytes.
 * @param algorithm  KEM or Signature algorithm identifier.
 * @param error      Out-error on length mismatch or unsupported
 *                   algorithm.
 * @return YES if `key`'s length matches the algorithm's public-key
 *         length, NO with `*error` set otherwise.
 */
+ (BOOL)validatePublicKey:(NSData *)key
                algorithm:(NSString *)algorithm
                    error:(NSError **)error;

/**
 * Validate a private-key candidate against the asymmetric algorithm's
 * expected length.
 *
 * Symmetric algorithms return NO with an "asymmetric required"
 * error.
 *
 * @param key        Candidate private-key bytes.
 * @param algorithm  KEM or Signature algorithm identifier.
 * @param error      Out-error on length mismatch or unsupported
 *                   algorithm.
 * @return YES if `key`'s length matches the algorithm's private-key
 *         length, NO with `*error` set otherwise.
 */
+ (BOOL)validatePrivateKey:(NSData *)key
                 algorithm:(NSString *)algorithm
                     error:(NSError **)error;

/**
 * Return every algorithm identifier registered in the catalog.
 *
 * Includes both Active and Reserved status entries. Order matches
 * the in-source allow-list definition order.
 *
 * @return Algorithm identifier strings; never `nil`.
 */
+ (NSArray<NSString *> *)allAlgorithms;

@end

NS_ASSUME_NONNULL_END

#endif
