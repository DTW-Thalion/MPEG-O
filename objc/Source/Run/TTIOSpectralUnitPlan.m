/*
 * TTIOSpectralUnitPlan.m
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */

#import "Run/TTIOSpectralUnitPlan.h"

#import <limits.h>

@implementation TTIOSpectralUnitPlan

+ (NSArray<NSValue *> *)unitsForSpectraFrom:(NSUInteger)from
                                         to:(NSUInteger)to
                                    offsets:(const unsigned long long *)offsets
                                    lengths:(const unsigned int *)lengths
                           blockValueStarts:(const unsigned long long *)blockValueStarts
                                      count:(NSUInteger)count
{
    NSMutableArray<NSValue *> *out = [NSMutableArray array];
    if (from >= to || count == 0 || !offsets || !lengths || !blockValueStarts) {
        return out;
    }

    NSUInteger b = 0;
    NSUInteger i = from;
    while (i < to) {
        /* Advance to the block owning spectrum i's first value. Blocks
         * with no spectrum start are skipped rather than emitted: a
         * spectrum longer than a block leaves the blocks it spans
         * owning nothing. */
        while (b + 1 < count && blockValueStarts[b + 1] <= offsets[i]) b++;
        unsigned long long blockEnd =
            (b + 1 < count) ? blockValueStarts[b + 1] : ULLONG_MAX;

        NSUInteger first = i;
        while (i < to && offsets[i] < blockEnd) i++;

        TTIOSpectralUnit u;
        u.block = b;
        u.firstSpectrum = first;
        u.nSpectra = i - first;
        u.valueStart = offsets[first];
        /* The extent runs to the end of the LAST spectrum in the unit,
         * which may lie past this block's end. */
        u.valueEnd = offsets[i - 1] + (unsigned long long)lengths[i - 1];
        [out addObject:[NSValue valueWithBytes:&u objCType:@encode(TTIOSpectralUnit)]];
    }
    return out;
}

@end
