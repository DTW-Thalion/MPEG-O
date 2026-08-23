/*
 * TTIOSpectralUnitPlan.h
 * TTI-O Objective-C Implementation
 *
 * Classes:       TTIOSpectralUnitPlan
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Run/TTIOSpectralUnitPlan.h
 *
 * Maps a range of spectra onto FLOAT_DELTA_ZSTD block boundaries.
 *
 * Spectral blocks are cut on value boundaries while a spectrum is
 * located by value offset, so block edges fall inside spectra. A
 * spectrum belongs to the block holding its FIRST value, which
 * partitions the spectra exactly once with no gap and no overlap.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * One scheduling unit: a run of whole spectra and the value extent
 * covering them.
 *
 * <code>valueEnd</code> may exceed the owning block's end when the
 * last spectrum straddles into the next block, so units are not byte
 * independent.
 */
typedef struct {
    NSUInteger block;             /**< owning block index */
    NSUInteger firstSpectrum;     /**< run-global index of the first spectrum */
    NSUInteger nSpectra;          /**< always >= 1; empty units are not emitted */
    unsigned long long valueStart;
    unsigned long long valueEnd;  /**< half-open */
} TTIOSpectralUnit;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Run/TTIOSpectralUnitPlan.h</p>
 *
 * <p>Pure mapping from a spectrum range to scheduling units. Holds no
 * state and performs no I/O.</p>
 *
 * <p><strong>API status:</strong> Internal.</p>
 */
@interface TTIOSpectralUnitPlan : NSObject

/**
 * Units covering spectra <code>[from, to)</code>, ascending.
 *
 * @param from             first spectrum index, inclusive
 * @param to               last spectrum index, exclusive
 * @param offsets          value offset of each spectrum, at least `to` entries
 * @param lengths          value count of each spectrum, at least `to` entries
 * @param blockValueStarts first value of each block, ascending
 * @param count            number of blocks
 * @return boxed TTIOSpectralUnit values; empty when from >= to.
 */
+ (NSArray<NSValue *> *)unitsForSpectraFrom:(NSUInteger)from
                                         to:(NSUInteger)to
                                    offsets:(const unsigned long long *)offsets
                                    lengths:(const unsigned int *)lengths
                           blockValueStarts:(const unsigned long long *)blockValueStarts
                                      count:(NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
