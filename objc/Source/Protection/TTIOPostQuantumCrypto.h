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
 * API status: Provisional . Subject to breaking changes
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
/**
 * Initialise a PQC keypair from raw public + private key bytes.
 *
 * Used by the keygen + key-load paths to package the two halves of a
 * post-quantum keypair into a single value object.
 *
 * @param publicKey   Public-key bytes (1568 for ML-KEM-1024, 2592 for
 *                    ML-DSA-87 verification key).
 * @param privateKey  Private-key bytes (3168 for ML-KEM-1024, 4896 for
 *                    ML-DSA-87 signing key).
 * @return New `TTIOPQCKeyPair` instance holding the supplied byte
 *         buffers (copied).
 */
- (instancetype)initWithPublicKey:(NSData *)publicKey
                        privateKey:(NSData *)privateKey;
@end

/** Result of a KEM encapsulation: ciphertext to store on disk + the
 *  shared secret (32 bytes for ML-KEM-1024, used downstream as an
 *  AES-256 KEK). */
@interface TTIOPQCKemEncapResult : NSObject
@property (nonatomic, readonly, copy) NSData *ciphertext;
@property (nonatomic, readonly, copy) NSData *sharedSecret;
/**
 * Initialise a KEM encapsulation result from its constituent fields.
 *
 * @param ciphertext    KEM ciphertext bytes (1568 for ML-KEM-1024).
 *                      Persisted alongside the encrypted payload so a
 *                      holder of the matching private key can recover
 *                      `sharedSecret` later.
 * @param sharedSecret  Newly-generated shared secret (32 bytes) used
 *                      downstream as an AES-256 KEK.
 * @return New `TTIOPQCKemEncapResult` instance holding the supplied
 *         byte buffers (copied).
 */
- (instancetype)initWithCiphertext:(NSData *)ciphertext
                       sharedSecret:(NSData *)sharedSecret;
@end

@interface TTIOPostQuantumCrypto : NSObject

/** YES iff liboqs was linked at build time. If NO, every sign /
 *  verify / encap / decap call below returns nil with
 *  TTIOErrorPQCUnavailable. */
+ (BOOL)isAvailable;

#pragma mark - ML-KEM-1024 (FIPS 203)

/**
 * Generate a fresh ML-KEM-1024 (FIPS 203) encapsulation keypair.
 *
 * The returned keypair has `publicKey.length == 1568` and
 * `privateKey.length == 3168`. Requires `+isAvailable == YES`;
 * otherwise returns `nil` with `TTIOErrorPQCUnavailable`.
 *
 * @param error  Out-error on liboqs failure or unavailable backend.
 * @return New `TTIOPQCKeyPair` on success, or `nil` with `*error` set.
 */
+ (nullable TTIOPQCKeyPair *)kemKeygenWithError:(NSError **)error;

/**
 * Encapsulate a fresh 32-byte shared secret under the recipient's
 * ML-KEM-1024 public key.
 *
 * Standard FIPS 203 encapsulation: the result carries both the KEM
 * ciphertext (to persist alongside the encrypted payload) and the
 * shared secret used as an AES-256 KEK for downstream wrapping.
 *
 * @param publicKey  Recipient's 1568-byte ML-KEM-1024 public key.
 * @param error      Out-error on bad key length or liboqs failure.
 * @return `TTIOPQCKemEncapResult` carrying `(ciphertext, sharedSecret)`,
 *         or `nil` with `*error` set.
 */
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

/**
 * Generate a fresh ML-DSA-87 (FIPS 204) signing keypair.
 *
 * The returned keypair has `publicKey.length == 2592` (verification
 * key) and `privateKey.length == 4896` (signing key). Requires
 * `+isAvailable == YES`.
 *
 * @param error  Out-error on liboqs failure or unavailable backend.
 * @return New `TTIOPQCKeyPair` on success, or `nil` with `*error` set.
 */
+ (nullable TTIOPQCKeyPair *)sigKeygenWithError:(NSError **)error;

/**
 * Sign `message` with an ML-DSA-87 (FIPS 204) signing key.
 *
 * Produces the raw 4627-byte signature. The signing key must be the
 * private half of a `+sigKeygenWithError:` result.
 *
 * @param privateKey  4896-byte ML-DSA-87 signing key.
 * @param message     Message bytes to sign (any length).
 * @param error       Out-error on bad key length or liboqs failure.
 * @return 4627-byte signature on success, or `nil` with `*error` set.
 */
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
