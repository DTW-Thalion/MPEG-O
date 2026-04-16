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
};

@interface MPGOCompoundField : NSObject <NSCopying>
@property (readonly, copy) NSString *name;
@property (readonly)       MPGOCompoundFieldKind kind;

+ (instancetype)fieldWithName:(NSString *)name kind:(MPGOCompoundFieldKind)kind;
- (instancetype)initWithName:(NSString *)name kind:(MPGOCompoundFieldKind)kind;
@end

#endif
