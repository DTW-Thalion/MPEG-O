/*
 * TTIOPixelSpectrum.m
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOPixelSpectrum.h"

@implementation TTIOPixelSpectrum

- (instancetype)initWithX:(NSUInteger)x
                        y:(NSUInteger)y
                        z:(NSUInteger)z
                       mz:(NSData *)mz
                intensity:(NSData *)intensity
{
    self = [super init];
    if (self) {
        _x = x;
        _y = y;
        _z = z;
        _mz = [mz copy];
        _intensity = [intensity copy];
    }
    return self;
}

@end
