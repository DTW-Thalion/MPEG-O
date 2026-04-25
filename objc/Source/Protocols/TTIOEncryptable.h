#ifndef TTIO_ENCRYPTABLE_H
#define TTIO_ENCRYPTABLE_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOAccessPolicy;

/**
 * Objects conforming to TTIOEncryptable support MPEG-G-style multi-level
 * protection. Encryption can be applied at dataset-group, dataset,
 * descriptor-stream, or access-unit granularity, enabling selective
 * protection (e.g. encrypting intensity values while leaving m/z and
 * scan metadata readable for indexing and search).
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.protocols.Encryptable
 *   Java:   global.thalion.ttio.protocols.Encryptable
 */
@protocol TTIOEncryptable <NSObject>

@required
- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error;

- (BOOL)decryptWithKey:(NSData *)key
                 error:(NSError **)error;

- (TTIOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy;

@end

#endif /* TTIO_ENCRYPTABLE_H */
