/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ENCRYPTED_TRANSPORT_H
#define TTIO_ENCRYPTED_TRANSPORT_H

#import <Foundation/Foundation.h>
#import "TTIOTransportWriter.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOEncryptedTransport</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOEncryptedTransport.h</p>
 *
 * <p>Transport layer for per-AU encrypted files. The writer pushes
 * ciphertext from a <code>&lt;channel&gt;_segments</code> compound
 * onto the wire unmodified (the server never decrypts in transit,
 * per <code>docs/transport-spec.md</code> §6.2). The reader
 * materialises an encrypted <code>.tio</code> on the receiver side
 * with the same wrapped DEK.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.encrypted</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.EncryptedTransport</code></p>
 */
@interface TTIOEncryptedTransport : NSObject

/**
 * @param path         Path to the candidate <code>.tio</code> file.
 * @param providerName Optional explicit provider name; pass
 *                     <code>nil</code> for scheme-based routing.
 * @return <code>YES</code> if the file on disk carries
 *         <code>opt_per_au_encryption</code>; <code>NO</code>
 *         otherwise.
 */
+ (BOOL)isPerAUEncryptedAtPath:(NSString *)path
                  providerName:(nullable NSString *)providerName;

/**
 * Emits a full transport stream from a per-AU-encrypted file through
 * <code>writer</code>. ProtectionMetadata precedes encrypted AUs;
 * AU flag bits set per transport-spec §3.1.1.
 *
 * @param ttioPath     Source <code>.tio</code> file path.
 * @param writer       Destination writer.
 * @param providerName Optional explicit provider name.
 * @param error        Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
+ (BOOL)writeEncryptedDataset:(NSString *)ttioPath
                       writer:(TTIOTransportWriter *)writer
                 providerName:(nullable NSString *)providerName
                        error:(NSError * _Nullable *)error;

/**
 * Materialises an encrypted transport stream from
 * <code>streamData</code> into <code>outputPath</code>. Preserves
 * ciphertext bytes verbatim.
 *
 * @param outputPath   Destination <code>.tio</code> path.
 * @param streamData   Source transport bytes.
 * @param providerName Optional explicit provider name.
 * @param error        Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
+ (BOOL)readEncryptedToPath:(NSString *)outputPath
                fromStream:(NSData *)streamData
               providerName:(nullable NSString *)providerName
                      error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
