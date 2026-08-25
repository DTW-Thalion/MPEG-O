/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Assembly/TTIOGraphLink.h"

@implementation TTIOGraphLink

- (instancetype)initWithFromSegment:(NSString *)fromSegment
                         fromOrient:(NSString *)fromOrient
                          toSegment:(NSString *)toSegment
                           toOrient:(NSString *)toOrient
                            overlap:(NSString *)overlap
                               tags:(NSString *)tags
{
    self = [super init];
    if (self) {
        _fromSegment = [fromSegment copy];
        _fromOrient = [fromOrient copy];
        _toSegment = [toSegment copy];
        _toOrient = [toOrient copy];
        _overlap = [overlap copy];
        _tags = [tags copy] ?: @"";
    }
    return self;
}

@end
