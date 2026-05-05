#ifndef TTIO_ENCRYPTABLE_H
#define TTIO_ENCRYPTABLE_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOAccessPolicy;

/**
 * <heading>TTIOEncryptable</heading>
 *
 * <p><em>Conforms To:</em> NSObject (root protocol)</p>
 * <p><em>Declared In:</em> Protocols/TTIOEncryptable.h</p>
 *
 * <p>Declares the interface for objects that support multi-level
 * cryptographic protection. Encryption can be applied at
 * dataset-group, dataset, descriptor-stream, or access-unit
 * granularity, enabling selective protection (e.g. encrypting
 * intensity values while leaving m/z and scan metadata readable for
 * indexing and search).</p>
 *
 * <p>The default cipher suite is AES-256-GCM with envelope key
 * wrapping. Concrete classes resolve the per-AU encryption key via
 * the supplied access policy or via a key-management callback.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.protocols.Encryptable</code><br/>
 * Java: <code>global.thalion.ttio.protocols.Encryptable</code></p>
 */
@protocol TTIOEncryptable <NSObject>

@required

/**
 * Encrypts the receiver in place at the requested granularity.
 *
 * @param key   Symmetric encryption key. Must match the byte length
 *              required by the active cipher suite (32 bytes for
 *              AES-256-GCM).
 * @param level Granularity of the seal. Per-dataset, per-stream, or
 *              per-access-unit; see <code>TTIOEncryptionLevel</code>.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success; <code>NO</code> with
 *         <code>error</code> populated on failure.
 */
- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error;

/**
 * Decrypts the receiver in place. Wrong keys fail cleanly via the
 * GCM authentication tag, never as partial-byte garbage.
 *
 * @param key   Symmetric decryption key.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success; <code>NO</code> with
 *         <code>error</code> populated on failure (key mismatch,
 *         malformed envelope, or missing wrapped-key blob).
 */
- (BOOL)decryptWithKey:(NSData *)key
                 error:(NSError **)error;

/**
 * @return The access policy currently associated with the receiver,
 *         or <code>nil</code> if none has been set.
 */
- (TTIOAccessPolicy *)accessPolicy;

/**
 * Replaces the access policy associated with the receiver.
 *
 * @param policy The new access policy. Pass <code>nil</code> to
 *               clear an existing policy.
 */
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy;

@end

#endif /* TTIO_ENCRYPTABLE_H */
