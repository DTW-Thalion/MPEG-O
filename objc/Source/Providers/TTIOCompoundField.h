/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_PROVIDERS_COMPOUND_FIELD_H
#define TTIO_PROVIDERS_COMPOUND_FIELD_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TTIOCompoundFieldKind) {
    TTIOCompoundFieldKindUInt32   = 0,
    TTIOCompoundFieldKindInt64    = 1,
    TTIOCompoundFieldKindFloat64  = 2,
    TTIOCompoundFieldKindVLString = 3,
    /* v1.0: variable-length byte buffer. Used by the per-AU
     * encryption <channel>_segments compound (ciphertext column)
     * and for fixed-length inline IV / TAG / semantic-header
     * blobs. Providers serialise values as NSData; on read a row's
     * value comes back as NSData. */
    TTIOCompoundFieldKindVLBytes  = 4,
};

/**
 * One field inside a compound-dataset record.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.providers.base.CompoundField
 *   Java:   com.dtwthalion.tio.providers.CompoundField
 */
@interface TTIOCompoundField : NSObject <NSCopying>
@property (readonly, copy) NSString *name;
@property (readonly)       TTIOCompoundFieldKind kind;

+ (instancetype)fieldWithName:(NSString *)name kind:(TTIOCompoundFieldKind)kind;
- (instancetype)initWithName:(NSString *)name kind:(TTIOCompoundFieldKind)kind;
@end

#endif
