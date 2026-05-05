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

/** YES iff ``algorithm`` is a known catalog entry with status Active. */
+ (BOOL)isSupported:(NSString *)algorithm;

/** YES iff ``algorithm`` is in the catalog (active or reserved). */
+ (BOOL)isRegistered:(NSString *)algorithm;

/** Category for the given algorithm. Returns @c TTIOCipherCategoryAEAD
 *  as a fallback for unknown inputs; check @c isRegistered: first. */
+ (TTIOCipherCategory)category:(NSString *)algorithm;

/** Fixed key length in bytes, or ``-1`` for variable-length keys
 *  (HMAC). For KEM/Signature algorithms this is the <b>public</b> key
 *  length. Returns ``0`` for unknown algorithms. */
+ (NSInteger)keyLength:(NSString *)algorithm;

/** Public-key length for KEM/Signature algorithms. Raises
 *  NSInvalidArgumentException for symmetric algorithms. @since 0.8 */
+ (NSInteger)publicKeySize:(NSString *)algorithm;

/** Private-key length for KEM/Signature algorithms. Raises
 *  NSInvalidArgumentException for symmetric algorithms. @since 0.8 */
+ (NSInteger)privateKeySize:(NSString *)algorithm;

/** Nonce / IV length in bytes. Zero for non-AEAD primitives. */
+ (NSInteger)nonceLength:(NSString *)algorithm;

/** Tag / signature length in bytes. */
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

/** Validate ``key`` as the <b>public</b> key for the asymmetric
 *  algorithm (KEM encapsulation / signature verification). Symmetric
 *  algorithms return NO. @since 0.8 */
+ (BOOL)validatePublicKey:(NSData *)key
                algorithm:(NSString *)algorithm
                    error:(NSError **)error;

/** Validate ``key`` as the <b>private</b> key for the asymmetric
 *  algorithm (KEM decapsulation / signing). Symmetric algorithms
 *  return NO. @since 0.8 */
+ (BOOL)validatePrivateKey:(NSData *)key
                 algorithm:(NSString *)algorithm
                     error:(NSError **)error;

/** List all known algorithm identifiers (active + reserved). */
+ (NSArray<NSString *> *)allAlgorithms;

@end

NS_ASSUME_NONNULL_END

#endif
