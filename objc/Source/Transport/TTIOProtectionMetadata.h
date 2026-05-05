/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_PROTECTION_METADATA_H
#define TTIO_PROTECTION_METADATA_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOProtectionMetadata</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOProtectionMetadata.h</p>
 *
 * <p>ProtectionMetadata packet payload as defined in
 * <code>docs/transport-spec.md</code> §4.4. Carries the cipher-suite
 * identifier, KEK algorithm, wrapped DEK, signature algorithm, and
 * verifier public key for a per-AU-encrypted transport stream.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: helpers in
 * <code>tests/test_transport_selective_access.py</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.ProtectionMetadata</code></p>
 */
@interface TTIOProtectionMetadata : NSObject

@property (nonatomic, readonly, copy) NSString *cipherSuite;
@property (nonatomic, readonly, copy) NSString *kekAlgorithm;
@property (nonatomic, readonly, strong) NSData *wrappedDek;
@property (nonatomic, readonly, copy) NSString *signatureAlgorithm;
@property (nonatomic, readonly, strong) NSData *publicKey;

/**
 * Designated initialiser.
 *
 * @param cipherSuite        Cipher-suite identifier
 *                           (e.g. <code>"AES-256-GCM"</code>).
 * @param kekAlgorithm       KEK wrap algorithm.
 * @param wrappedDek         DEK wrapped under the KEK.
 * @param signatureAlgorithm Signature algorithm name.
 * @param publicKey          Verifier public key bytes.
 * @return An initialised metadata payload.
 */
- (instancetype)initWithCipherSuite:(NSString *)cipherSuite
                         kekAlgorithm:(NSString *)kekAlgorithm
                          wrappedDek:(NSData *)wrappedDek
                   signatureAlgorithm:(NSString *)signatureAlgorithm
                            publicKey:(NSData *)publicKey;

/**
 * @return The wire-format payload bytes.
 */
- (NSData *)encode;

/**
 * Decodes a wire-format payload.
 *
 * @param data Wire bytes.
 * @return The decoded metadata, or <code>nil</code> on malformed
 *         input.
 */
+ (nullable instancetype)decodeFromData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END

#endif
