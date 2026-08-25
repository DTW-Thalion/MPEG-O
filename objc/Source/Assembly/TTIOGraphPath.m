/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Assembly/TTIOGraphPath.h"

@implementation TTIOGraphPath

- (instancetype)initWithName:(NSString *)name
                 segmentList:(NSString *)segmentList
                    overlaps:(NSString *)overlaps
                        tags:(NSString *)tags
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _segmentList = [segmentList copy];
        _overlaps = [overlaps copy];
        _tags = [tags copy] ?: @"";
    }
    return self;
}

@end
