/*
 * TTIOPostQuantumCrypto.h
 * TTI-O Objective-C Implementation
 *
 * ML-KEM-1024 + ML-DSA-87 primitives. Thin wrapper over liboqs
 * (Open Quantum Safe) giving the rest of libTTIO a stable surface
 * for FIPS 203 (ML-KEM-1024) key encapsulation and FIPS 204
 * (ML-DSA-87) digital signatures. Python uses the liboqs-python
 * bindings over the same shared library; Java uses Bouncy Castle
 * 1.79+ instead (see docs/pqc.md).
 *
 * Availability
 * ------------
 * The ObjC build links liboqs at compile time when
 * $OQS_PREFIX/include/oqs/oqs.h is present (see GNUmakefile.preamble
 * and check-deps.sh). If liboqs is not found at build time, the PQC
 * entry points in this class return NO with TTIOErrorPQCUnavailable
 * at runtime — existing AES-GCM / HMAC code paths remain fully
 * functional.
 *
 * Role map
 * --------
 *  * Encapsulation (sender, writer) takes a public key and returns
 *    (ciphertext, shared_secret).
 *  * Decapsulation (receiver, reader) takes a private key and the
 *    KEM ciphertext and returns shared_secret.
 *  * Sign takes a signing private key and message; returns signature.
 *  * Verify takes a verification public key, message, and signature;
 *    returns YES / NO.
 *
 * Pinned sizes (FIPS 203 / 204):
 *   ML-KEM-1024  pk 1568 · sk 3168 · ct 1568 · ss 32
 *   ML-DSA-87    pk 2592 · sk 4896 · sig 4627
 *
 * API status: Provisional (v0.8). Subject to breaking changes
 * through v0.8; Stable at v1.0.
 *
 * Cross-language equivalents:
 *   Python: ttio.pqc
 *   Java:   global.thalion.ttio.protection.PostQuantumCrypto
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_POST_QUANTUM_CRYPTO_H
#define TTIO_POST_QUANTUM_CRYPTO_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Raw-bytes PQC keypair. */
@interface TTIOPQCKeyPair : NSObject
@property (nonatomic, readonly, copy) NSData *publicKey;
@property (nonatomic, readonly, copy) NSData *privateKey;
- (instancetype)initWithPublicKey:(NSData *)publicKey
                        privateKey:(NSData *)privateKey;
@end

/** Result of a KEM encapsulation: ciphertext to store on disk + the
 *  shared secret (32 bytes for ML-KEM-1024, used downstream as an
 *  AES-256 KEK). */
@interface TTIOPQCKemEncapResult : NSObject
@property (nonatomic, readonly, copy) NSData *ciphertext;
@property (nonatomic, readonly, copy) NSData *sharedSecret;
- (instancetype)initWithCiphertext:(NSData *)ciphertext
                       sharedSecret:(NSData *)sharedSecret;
@end

@interface TTIOPostQuantumCrypto : NSObject

/** YES iff liboqs was linked at build time. If NO, every sign /
 *  verify / encap / decap call below returns nil with
 *  TTIOErrorPQCUnavailable. */
+ (BOOL)isAvailable;

#pragma mark - ML-KEM-1024 (FIPS 203)

/** Generate a fresh ML-KEM-1024 encapsulation keypair. */
+ (nullable TTIOPQCKeyPair *)kemKeygenWithError:(NSError **)error;

/** Encapsulate a fresh 32-byte shared secret under ``publicKey``.
 *  ``publicKey`` must be 1568 bytes (ML-KEM-1024 pk length). */
+ (nullable TTIOPQCKemEncapResult *)kemEncapsulateWithPublicKey:(NSData *)publicKey
                                                            error:(NSError **)error;

/** Recover the shared secret from a KEM ciphertext using
 *  ``privateKey``. ``privateKey`` is 3168 bytes, ``ciphertext`` is
 *  1568 bytes; output is 32 bytes. ML-KEM decapsulation is
 *  unauthenticated — downstream AES-GCM unwrap must authenticate. */
+ (nullable NSData *)kemDecapsulateWithPrivateKey:(NSData *)privateKey
                                         ciphertext:(NSData *)ciphertext
                                              error:(NSError **)error;

#pragma mark - ML-DSA-87 (FIPS 204)

/** Generate a fresh ML-DSA-87 signing keypair. */
+ (nullable TTIOPQCKeyPair *)sigKeygenWithError:(NSError **)error;

/** Sign ``message`` with the 4896-byte ML-DSA-87 signing key.
 *  Returns the raw 4627-byte signature. */
+ (nullable NSData *)sigSignWithPrivateKey:(NSData *)privateKey
                                    message:(NSData *)message
                                      error:(NSError **)error;

/** Verify ``signature`` against ``message`` under the 2592-byte
 *  ML-DSA-87 verification public key. Returns YES on success, NO on
 *  a well-formed-but-invalid signature. Malformed inputs populate
 *  ``error`` with a descriptive message. */
+ (BOOL)sigVerifyWithPublicKey:(NSData *)publicKey
                         message:(NSData *)message
                       signature:(NSData *)signature
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_POST_QUANTUM_CRYPTO_H */
