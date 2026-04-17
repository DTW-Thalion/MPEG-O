#ifndef MPGO_ENCRYPTABLE_H
#define MPGO_ENCRYPTABLE_H

#import <Foundation/Foundation.h>
#import "ValueClasses/MPGOEnums.h"

@class MPGOAccessPolicy;

/**
 * Objects conforming to MPGOEncryptable support MPEG-G-style multi-level
 * protection. Encryption can be applied at dataset-group, dataset,
 * descriptor-stream, or access-unit granularity, enabling selective
 * protection (e.g. encrypting intensity values while leaving m/z and
 * scan metadata readable for indexing and search).
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.protocols.Encryptable
 *   Java:   com.dtwthalion.mpgo.protocols.Encryptable
 */
@protocol MPGOEncryptable <NSObject>

@required
- (BOOL)encryptWithKey:(NSData *)key
                 level:(MPGOEncryptionLevel)level
                 error:(NSError **)error;

- (BOOL)decryptWithKey:(NSData *)key
                 error:(NSError **)error;

- (MPGOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(MPGOAccessPolicy *)policy;

@end

#endif /* MPGO_ENCRYPTABLE_H */
