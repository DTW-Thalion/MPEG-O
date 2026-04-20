/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef MPGO_PROVIDERS_COMPOUND_FIELD_H
#define MPGO_PROVIDERS_COMPOUND_FIELD_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MPGOCompoundFieldKind) {
    MPGOCompoundFieldKindUInt32   = 0,
    MPGOCompoundFieldKindInt64    = 1,
    MPGOCompoundFieldKindFloat64  = 2,
    MPGOCompoundFieldKindVLString = 3,
    /* v1.0: variable-length byte buffer. Used by the per-AU
     * encryption <channel>_segments compound (ciphertext column)
     * and for fixed-length inline IV / TAG / semantic-header
     * blobs. Providers serialise values as NSData; on read a row's
     * value comes back as NSData. */
    MPGOCompoundFieldKindVLBytes  = 4,
};

/**
 * One field inside a compound-dataset record.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.base.CompoundField
 *   Java:   com.dtwthalion.mpgo.providers.CompoundField
 */
@interface MPGOCompoundField : NSObject <NSCopying>
@property (readonly, copy) NSString *name;
@property (readonly)       MPGOCompoundFieldKind kind;

+ (instancetype)fieldWithName:(NSString *)name kind:(MPGOCompoundFieldKind)kind;
- (instancetype)initWithName:(NSString *)name kind:(MPGOCompoundFieldKind)kind;
@end

#endif
