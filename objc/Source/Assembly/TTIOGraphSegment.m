/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Assembly/TTIOGraphSegment.h"

@implementation TTIOGraphSegment

- (instancetype)initWithName:(NSString *)name
                    sequence:(NSData *)sequence
                        tags:(NSString *)tags
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _sequence = [sequence copy];
        _tags = [tags copy] ?: @"";
    }
    return self;
}

@end
