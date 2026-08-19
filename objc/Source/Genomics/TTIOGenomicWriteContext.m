/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOGenomicWriteContext.h"

@implementation TTIOGenomicWriteContext

- (instancetype)init
{
    if ((self = [super init])) {
        _qualStrategyHint = -1;
    }
    return self;
}

+ (instancetype)none { return [[self alloc] init]; }

+ (instancetype)contextWithChromNameToId:(NSMutableDictionary<NSString *, NSNumber *> *)map
                            referenceMD5:(NSData *)md5
{
    TTIOGenomicWriteContext *c = [[self alloc] init];
    c.chromNameToId = map;
    c.referenceMD5 = md5;
    return c;
}

@end
