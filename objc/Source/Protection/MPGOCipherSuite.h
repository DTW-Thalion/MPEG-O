/*
 * MPGOCipherSuite.h — cipher-suite catalog and algorithm-dispatched
 * parameter helpers (v0.7 M48).
 *
 * Pre-v0.7, encryption / signing / key-wrap APIs accepted an implicit
 * fixed algorithm (AES-256-GCM for bulk, HMAC-SHA256 for signatures).
 * Key sizes and nonce lengths were hardcoded module-level constants.
 *
 * v0.7 M48 generalises the public API with an ``algorithm:`` parameter
 * backed by this catalog. The intent is to shape the parameter hole
 * so M49's post-quantum binding is a pure plug-in — no API change —
 * once ML-KEM-1024 / ML-DSA-87 are ready.
 *
 * Reserved algorithms (``ml-kem-1024``, ``ml-dsa-87``, ``shake256``)
 * are registered in the catalog but fail ``validateKey:error:`` with
 * a clear "reserved for M49" error until the primitives ship.
 *
 * Binding decision 39: this is a static allow-list, not a plugin
 * registry. Adding a new algorithm is a source-code change.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.cipher_suite
 *   Java:   com.dtwthalion.mpgo.protection.CipherSuite
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_CIPHER_SUITE_H
#define MPGO_CIPHER_SUITE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MPGOCipherCategory) {
    MPGOCipherCategoryAEAD      = 0,
    MPGOCipherCategoryKEM       = 1,
    MPGOCipherCategoryMAC       = 2,
    MPGOCipherCategorySignature = 3,
    MPGOCipherCategoryHash      = 4,
    MPGOCipherCategoryXOF       = 5,
};

typedef NS_ENUM(NSInteger, MPGOCipherStatus) {
    MPGOCipherStatusActive   = 0,
    MPGOCipherStatusReserved = 1,
};

@interface MPGOCipherSuite : NSObject

/** YES iff ``algorithm`` is a known catalog entry with status Active. */
+ (BOOL)isSupported:(NSString *)algorithm;

/** YES iff ``algorithm`` is in the catalog (active or reserved). */
+ (BOOL)isRegistered:(NSString *)algorithm;

/** Category for the given algorithm. Returns @c MPGOCipherCategoryAEAD
 *  as a fallback for unknown inputs; check @c isRegistered: first. */
+ (MPGOCipherCategory)category:(NSString *)algorithm;

/** Fixed key length in bytes, or ``-1`` for variable-length keys
 *  (HMAC). Returns ``0`` for unknown algorithms. */
+ (NSInteger)keyLength:(NSString *)algorithm;

/** Nonce / IV length in bytes. Zero for non-AEAD primitives. */
+ (NSInteger)nonceLength:(NSString *)algorithm;

/** Tag / signature length in bytes. */
+ (NSInteger)tagLength:(NSString *)algorithm;

/** Validate that ``key`` has the correct length for ``algorithm``.
 *  Returns NO and populates @c error on mismatch. Reserved or unknown
 *  algorithms return NO with an "algorithm not supported" error. */
+ (BOOL)validateKey:(NSData *)key
          algorithm:(NSString *)algorithm
              error:(NSError **)error;

/** List all known algorithm identifiers (active + reserved). */
+ (NSArray<NSString *> *)allAlgorithms;

@end

NS_ASSUME_NONNULL_END

#endif
