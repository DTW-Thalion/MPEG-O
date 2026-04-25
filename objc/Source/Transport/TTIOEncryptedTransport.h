/*
 * TTIOEncryptedTransport — v1.0.
 *
 * Transport layer for per-AU encrypted files. Writer pushes
 * ciphertext from a <channel>_segments compound onto the wire
 * unmodified (the server never decrypts in transit, per
 * docs/transport-spec.md §6.2). Reader materialises an encrypted
 * .tio on the receiver side with the same wrapped DEK.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.encrypted
 *   Java:   com.dtwthalion.ttio.transport.EncryptedTransport
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ENCRYPTED_TRANSPORT_H
#define TTIO_ENCRYPTED_TRANSPORT_H

#import <Foundation/Foundation.h>
#import "TTIOTransportWriter.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOEncryptedTransport : NSObject

/** YES if the file on disk carries ``opt_per_au_encryption``. */
+ (BOOL)isPerAUEncryptedAtPath:(NSString *)path
                  providerName:(nullable NSString *)providerName;

/** Emit a full transport stream from a per-AU-encrypted file
 *  through ``writer``. ProtectionMetadata precedes encrypted AUs;
 *  AU flag bits set per transport-spec §3.1.1. */
+ (BOOL)writeEncryptedDataset:(NSString *)ttioPath
                       writer:(TTIOTransportWriter *)writer
                 providerName:(nullable NSString *)providerName
                        error:(NSError * _Nullable *)error;

/** Materialise an encrypted transport stream from ``streamData``
 *  into ``outputPath``. Preserves ciphertext bytes verbatim. */
+ (BOOL)readEncryptedToPath:(NSString *)outputPath
                fromStream:(NSData *)streamData
               providerName:(nullable NSString *)providerName
                      error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
