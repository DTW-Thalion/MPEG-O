/*
 * TTIOProtectionMetadata — v0.10 M71.
 *
 * ProtectionMetadata packet payload per
 * docs/transport-spec.md §4.4. Cross-language equivalents:
 * Python helpers in tests/test_transport_selective_access.py,
 * Java global.thalion.ttio.transport.ProtectionMetadata.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_PROTECTION_METADATA_H
#define TTIO_PROTECTION_METADATA_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTIOProtectionMetadata : NSObject

@property (nonatomic, readonly, copy) NSString *cipherSuite;
@property (nonatomic, readonly, copy) NSString *kekAlgorithm;
@property (nonatomic, readonly, strong) NSData *wrappedDek;
@property (nonatomic, readonly, copy) NSString *signatureAlgorithm;
@property (nonatomic, readonly, strong) NSData *publicKey;

- (instancetype)initWithCipherSuite:(NSString *)cipherSuite
                         kekAlgorithm:(NSString *)kekAlgorithm
                          wrappedDek:(NSData *)wrappedDek
                   signatureAlgorithm:(NSString *)signatureAlgorithm
                            publicKey:(NSData *)publicKey;

- (NSData *)encode;

+ (nullable instancetype)decodeFromData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END

#endif
