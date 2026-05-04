// TestOffsetsCumsum.m — v1.10 #10 unit tests for TTIOOffsetsFromLengths.
//
// The companion writer/reader dispatch behaviour is exercised by the
// existing TestM82GenomicRun, TestM90GenomicProtection, and TestM90Final
// tests (all of which now assert on offsets being absent from disk by
// default — the L4-era assertions were flipped during the v1.10 #10
// ship). This file focuses on the cumsum helper itself, which is the
// load-bearing piece — uint32→uint64 accumulator that mustn't overflow
// on a >4 GB genomic run even when stored lengths are uint32.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Genomics/TTIOGenomicIndex.h"

void testOffsetsCumsum(void);

static NSData *u32Data(const uint32_t *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(uint32_t)];
}

static void readU64(NSData *d, uint64_t *out, NSUInteger n)
{
    PASS_EQUAL(@(d.length), @(n * sizeof(uint64_t)),
               "offsets blob has expected uint64 length");
    memcpy(out, d.bytes, n * sizeof(uint64_t));
}

static void testEmptyInput(void)
{
    NSData *out = TTIOOffsetsFromLengths([NSData data]);
    PASS(out != nil, "empty lengths returns non-nil NSData");
    PASS_EQUAL(@(out.length), @(0), "empty offsets blob");
}

static void testSingleLength(void)
{
    uint32_t lens[1] = {100};
    NSData *out = TTIOOffsetsFromLengths(u32Data(lens, 1));
    PASS_EQUAL(@(out.length), @(sizeof(uint64_t)),
               "single-length output is 1 uint64");
    uint64_t buf[1];
    readU64(out, buf, 1);
    PASS_EQUAL(@(buf[0]), @(0), "single-length offset[0] = 0");
}

static void testTypicalLengths(void)
{
    uint32_t lens[5] = {100, 50, 75, 100, 25};
    NSData *out = TTIOOffsetsFromLengths(u32Data(lens, 5));
    uint64_t buf[5];
    readU64(out, buf, 5);
    uint64_t expected[5] = {0, 100, 150, 225, 325};
    for (int i = 0; i < 5; i++) {
        PASS_EQUAL(@(buf[i]), @(expected[i]),
                   "typical lengths cumsum index %d", i);
    }
}

static void testUniformLengths(void)
{
    uint32_t lens[20];
    for (int i = 0; i < 20; i++) lens[i] = 150;
    NSData *out = TTIOOffsetsFromLengths(u32Data(lens, 20));
    uint64_t buf[20];
    readU64(out, buf, 20);
    for (uint64_t i = 0; i < 20; i++) {
        PASS_EQUAL(@(buf[i]), @(i * 150ULL),
                   "uniform lengths offset[%llu]", (unsigned long long)i);
    }
}

// The whole point of v1.10: 3 reads × 2^31 bytes each must produce
// offsets [0, 2^31, 2^32]. A uint32 accumulator would silently wrap
// at 2^32; the production helper accumulates into uint64 to stay safe
// on >4 GB genomic runs.
static void testOverflowSafeUint32ToUint64(void)
{
    uint32_t lens[3] = {0x80000000U, 0x80000000U, 0x80000000U};  // 3 × 2^31
    NSData *out = TTIOOffsetsFromLengths(u32Data(lens, 3));
    uint64_t buf[3];
    readU64(out, buf, 3);
    PASS_EQUAL(@(buf[0]), @(0ULL),                "offset[0] = 0");
    PASS_EQUAL(@(buf[1]), @((uint64_t)1ULL << 31), "offset[1] = 2^31 (no wrap)");
    PASS_EQUAL(@(buf[2]), @((uint64_t)1ULL << 32), "offset[2] = 2^32 (no wrap)");
}

void testOffsetsCumsum(void)
{
    testEmptyInput();
    testSingleLength();
    testTypicalLengths();
    testUniformLengths();
    testOverflowSafeUint32ToUint64();
}
