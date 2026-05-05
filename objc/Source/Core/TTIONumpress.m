/*
 * TTIONumpress.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIONumpress
 * Inherits From: NSObject
 * Declared In:   Core/TTIONumpress.h
 *
 * Lossy numeric compression for monotonically-varying float64
 * signals (m/z, retention times). Clean-room from Teleman et al.
 * 2014 — fixed-point scale + first-difference quantisation.
 * Byte-identical with the Python and Java implementations by
 * construction.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIONumpress.h"
#import <math.h>

@implementation TTIONumpress

+ (int64_t)scaleForValueRangeMin:(double)minValue max:(double)maxValue
{
    double absMax = fabs(minValue) > fabs(maxValue) ? fabs(minValue)
                                                    : fabs(maxValue);
    if (absMax == 0.0 || !isfinite(absMax)) {
        return 1;  // degenerate case — 1× scale is still valid
    }
    // 2^62 - 1 ≈ 4.6e18. For absMax = 2000 (typical m/z), the scale
    // comes out to ~2.3e15 so the quantised integer has >50 bits of
    // precision — far more than the ~1 ppm requirement.
    double headroom = (double)((1LL << 62) - 1);
    double scale = floor(headroom / absMax);
    if (scale < 1.0) scale = 1.0;
    return (int64_t)scale;
}

+ (BOOL)encodeFloat64:(const double *)values
                count:(NSUInteger)count
                scale:(int64_t)scale
            outDeltas:(int64_t *)outDeltas
{
    if (count == 0 || !values || !outDeltas) return NO;
    if (scale <= 0) return NO;

    double dScale = (double)scale;
    int64_t prev = (int64_t)llround(values[0] * dScale);
    outDeltas[0] = prev;  // first entry is the absolute quantised value
    for (NSUInteger i = 1; i < count; i++) {
        int64_t q = (int64_t)llround(values[i] * dScale);
        outDeltas[i] = q - prev;
        prev = q;
    }
    return YES;
}

+ (BOOL)decodeInt64:(const int64_t *)deltas
              count:(NSUInteger)count
              scale:(int64_t)scale
         outValues:(double *)outValues
{
    if (count == 0 || !deltas || !outValues) return NO;
    if (scale <= 0) return NO;

    double dScale = (double)scale;
    int64_t running = deltas[0];
    outValues[0] = (double)running / dScale;
    for (NSUInteger i = 1; i < count; i++) {
        running += deltas[i];
        outValues[i] = (double)running / dScale;
    }
    return YES;
}

@end
