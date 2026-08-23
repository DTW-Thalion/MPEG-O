/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * -[TTIOAcquisitionRun iterBlocksFrom:to:threads:error:usingBlock:] and
 * the unit plan behind it.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Run/TTIOSpectralUnitPlan.h"

/* 6 spectra of 100 values; blocks start every 250 values, so no block
 * edge lands on a spectrum edge:
 *   spectra: [0,100) [100,200) [200,300) [300,400) [400,500) [500,600)
 *   blocks:  b0 [0,250)   b1 [250,500)   b2 [500,...)
 *   owner by first value: s0,s1,s2 -> b0 ; s3,s4 -> b1 ; s5 -> b2
 */
static void siuPlanBasics(void)
{
    unsigned long long off[6] = {0, 100, 200, 300, 400, 500};
    unsigned int len[6]       = {100, 100, 100, 100, 100, 100};
    unsigned long long bs[3]  = {0, 250, 500};

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:0 to:6
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:3];
    PASS(u.count == 3, "unit plan: 3 units for 6 spectra over 3 blocks (%lu)",
         (unsigned long)u.count);
    if (u.count != 3) return;

    TTIOSpectralUnit a; [u[0] getValue:&a];
    PASS(a.block == 0 && a.firstSpectrum == 0 && a.nSpectra == 3,
         "unit plan: b0 owns s0..s2 (block=%lu first=%lu n=%lu)",
         (unsigned long)a.block, (unsigned long)a.firstSpectrum,
         (unsigned long)a.nSpectra);
    PASS(a.valueStart == 0 && a.valueEnd == 300,
         "unit plan: b0 extent [0,300) (%llu,%llu)", a.valueStart, a.valueEnd);

    TTIOSpectralUnit b; [u[1] getValue:&b];
    PASS(b.block == 1 && b.firstSpectrum == 3 && b.nSpectra == 2,
         "unit plan: b1 owns s3..s4 (block=%lu first=%lu n=%lu)",
         (unsigned long)b.block, (unsigned long)b.firstSpectrum,
         (unsigned long)b.nSpectra);
    /* s4 ends at 500, which is b2's first value: the extent runs past
     * the owning block's end, so units are not byte independent. */
    PASS(b.valueStart == 300 && b.valueEnd == 500,
         "unit plan: b1 extent [300,500) crosses its own block end (%llu,%llu)",
         b.valueStart, b.valueEnd);

    TTIOSpectralUnit c; [u[2] getValue:&c];
    PASS(c.block == 2 && c.firstSpectrum == 5 && c.nSpectra == 1,
         "unit plan: b2 owns s5 (block=%lu first=%lu n=%lu)",
         (unsigned long)c.block, (unsigned long)c.firstSpectrum,
         (unsigned long)c.nSpectra);
}

/* A range starting part-way into a block reports run-global indices. */
static void siuPlanMidBlockStart(void)
{
    unsigned long long off[6] = {0, 100, 200, 300, 400, 500};
    unsigned int len[6]       = {100, 100, 100, 100, 100, 100};
    unsigned long long bs[3]  = {0, 250, 500};

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:1 to:4
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:3];
    PASS(u.count == 2, "unit plan: mid-block range spans 2 units (%lu)",
         (unsigned long)u.count);
    if (u.count != 2) return;

    TTIOSpectralUnit a; [u[0] getValue:&a];
    PASS(a.firstSpectrum == 1 && a.nSpectra == 2,
         "unit plan: clipped head unit is s1..s2 (first=%lu n=%lu)",
         (unsigned long)a.firstSpectrum, (unsigned long)a.nSpectra);
    PASS(a.valueStart == 100 && a.valueEnd == 300,
         "unit plan: clipped head extent [100,300) (%llu,%llu)",
         a.valueStart, a.valueEnd);

    TTIOSpectralUnit b; [u[1] getValue:&b];
    PASS(b.firstSpectrum == 3 && b.nSpectra == 1,
         "unit plan: clipped tail unit is s3 only (first=%lu n=%lu)",
         (unsigned long)b.firstSpectrum, (unsigned long)b.nSpectra);
}

/* One spectrum longer than a block: the blocks it spans own no spectrum
 * start and must not produce empty units. */
static void siuPlanSpectrumLongerThanBlock(void)
{
    unsigned long long off[2] = {0, 1000};
    unsigned int len[2]       = {1000, 10};
    unsigned long long bs[5]  = {0, 250, 500, 750, 1000};

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:0 to:2
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:5];
    PASS(u.count == 2, "unit plan: straddling spectrum yields 2 units, not 5 (%lu)",
         (unsigned long)u.count);
    BOOL noneEmpty = YES;
    for (NSValue *v in u) {
        TTIOSpectralUnit s; [v getValue:&s];
        if (s.nSpectra < 1) noneEmpty = NO;
    }
    PASS(noneEmpty, "unit plan: no empty unit emitted");
}

static void siuPlanEmptyRange(void)
{
    unsigned long long off[2] = {0, 100};
    unsigned int len[2]       = {100, 100};
    unsigned long long bs[1]  = {0};
    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:3 to:3
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:1];
    PASS(u.count == 0, "unit plan: empty range yields no units (%lu)",
         (unsigned long)u.count);
}

/* Every spectrum exactly once, no gaps, no overlap. */
static void siuPlanPartitions(void)
{
    const NSUInteger N = 97;
    unsigned long long off[97]; unsigned int len[97];
    unsigned long long cursor = 0;
    for (NSUInteger i = 0; i < N; i++) {
        len[i] = (unsigned int)(7 + (i % 13));
        off[i] = cursor; cursor += len[i];
    }
    unsigned long long bs[9];
    for (NSUInteger b = 0; b < 9; b++) bs[b] = b * (cursor / 9);

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:0 to:N
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:9];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
    NSUInteger expectNext = 0;
    BOOL tiles = YES;
    for (NSValue *v in u) {
        TTIOSpectralUnit s; [v getValue:&s];
        if (s.firstSpectrum != expectNext) tiles = NO;
        [seen addIndexesInRange:NSMakeRange(s.firstSpectrum, s.nSpectra)];
        expectNext = s.firstSpectrum + s.nSpectra;
    }
    PASS(tiles, "unit plan: units tile without gaps or overlap");
    PASS(seen.count == N && expectNext == N,
         "unit plan: all %lu spectra covered exactly once (%lu)",
         (unsigned long)N, (unsigned long)seen.count);
}

void testSpectralIterBlocks(void)
{
    siuPlanBasics();
    siuPlanMidBlockStart();
    siuPlanSpectrumLongerThanBlock();
    siuPlanEmptyRange();
    siuPlanPartitions();
}
