// TestGenomicIndexRegionQuery.m — PO1 (P1.2) equivalence test.
//
// Mirrors the just-merged Java PJ1 change: TTIOGenomicIndex region and
// flag queries must return IDENTICAL NSIndexSets after the disk-loaded
// interned-id ("vectorized uint16 scan") path replaces the per-read
// `isEqualToString:` scan. This test pins the contract on BOTH surfaces:
//
//   • DISK-LOADED index (interned chromosome_ids present) — the fast path.
//   • IN-MEMORY index (public initializer, no ids) — the string fallback.
//
// For every (chromosome, start, end) query and every flag mask, the
// assertion compares -indicesForRegion:/-indicesForFlag: against an
// INDEPENDENT reference NSIndexSet recomputed from the public accessors
// (-chromosomeAt:/-positionAt:/-flagsAt:). isEqualToIndexSet: checks
// both membership and order-agnostic identity; ascending order is an
// intrinsic property of NSIndexSet so identical membership ⇒ identical set.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOProviderRegistry.h"
#include <unistd.h>

void testGenomicIndexRegionQuery(void);

// ── Fixture ────────────────────────────────────────────────────────
//
// 8 reads across 3 chromosomes with deliberately varied positions so the
// boundary cases below are exercised:
//
//   i  chrom  position  flags
//   0  chr1     100      0
//   1  chr1     200      0x4
//   2  chr2     100      0x10
//   3  chr1     300      0x1
//   4  chr2     250      0
//   5  chrX     100      0x4 | 0x10
//   6  chr1     200      0          (duplicate position on chr1 with read 1)
//   7  chr2     100      0          (duplicate position on chr2 with read 2)
//
// "chr1" appears first → interned id 0; "chr2" → 1; "chrX" → 2.

static const int64_t  kPositions[8] = {100, 200, 100, 300, 250, 100, 200, 100};
static const uint32_t kFlags[8]     = {0, 0x4, 0x10, 0x1, 0, 0x14, 0, 0};
static NSArray<NSString *> *fixtureChroms(void)
{
    return @[@"chr1", @"chr1", @"chr2", @"chr1", @"chr2", @"chrX", @"chr1", @"chr2"];
}

static TTIOGenomicIndex *makeInMemoryIndex(void)
{
    NSArray<NSString *> *chroms = fixtureChroms();
    NSUInteger n = chroms.count;
    uint64_t offsets[8]; uint32_t lengths[8]; uint8_t mapqs[8];
    for (NSUInteger i = 0; i < n; i++) {
        offsets[i] = i * 150; lengths[i] = 150; mapqs[i] = 60;
    }
    return [[TTIOGenomicIndex alloc]
        initWithOffsets:[NSData dataWithBytes:offsets length:n * sizeof(uint64_t)]
                lengths:[NSData dataWithBytes:lengths length:n * sizeof(uint32_t)]
            chromosomes:chroms
              positions:[NSData dataWithBytes:kPositions length:n * sizeof(int64_t)]
       mappingQualities:[NSData dataWithBytes:mapqs length:n * sizeof(uint8_t)]
                  flags:[NSData dataWithBytes:kFlags length:n * sizeof(uint32_t)]];
}

// ── Independent reference oracles (use only public accessors) ──────

static NSIndexSet *referenceRegion(TTIOGenomicIndex *idx,
                                   NSString *chromosome,
                                   int64_t start, int64_t end)
{
    NSMutableIndexSet *exp = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < idx.count; i++) {
        if ([[idx chromosomeAt:i] isEqualToString:chromosome]
            && [idx positionAt:i] >= start
            && [idx positionAt:i] < end) {
            [exp addIndex:i];
        }
    }
    return exp;
}

static NSIndexSet *referenceFlag(TTIOGenomicIndex *idx, uint32_t mask)
{
    NSMutableIndexSet *exp = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < idx.count; i++) {
        if (([idx flagsAt:i] & mask) != 0) [exp addIndex:i];
    }
    return exp;
}

// ── Query battery shared across disk + in-memory surfaces ──────────

static void runQueryBattery(TTIOGenomicIndex *idx, const char *surface)
{
    // Each tuple: chromosome, start, end. Cover present sub-range, full
    // range, empty (start==end), inclusive-start/exclusive-end boundary,
    // and an absent chromosome.
    struct { NSString *chrom; int64_t start; int64_t end; const char *desc; } cases[] = {
        { @"chr1",  100, 400, "chr1 full range (all positions)" },
        { @"chr1",  150, 350, "chr1 sub-range excluding pos 100" },
        { @"chr2",  100, 251, "chr2 includes 250 (end exclusive boundary)" },
        { @"chr2",  100, 250, "chr2 excludes 250 (end is exclusive)" },
        { @"chr1",  200, 200, "chr1 empty range (start==end)" },
        { @"chr1",  100, 101, "chr1 start inclusive (pos 100 in [100,101))" },
        { @"chrX",  100, 101, "chrX single read at boundary" },
        { @"chrX",    0, 100, "chrX excludes 100 (end exclusive)" },
        { @"chrY",    0, 1000000, "absent chromosome → empty" },
        { @"chr1", -100, 50,  "chr1 below all positions → empty" },
    };
    for (size_t k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        NSIndexSet *actual = [idx indicesForRegion:cases[k].chrom
                                             start:cases[k].start
                                               end:cases[k].end];
        NSIndexSet *expected = referenceRegion(idx, cases[k].chrom,
                                               cases[k].start, cases[k].end);
        PASS([actual isEqualToIndexSet:expected],
             "PO1 [%s]: indicesForRegion %s (actual=%@ expected=%@)",
             surface, cases[k].desc, actual, expected);
    }

    uint32_t masks[] = {0x4, 0x10, 0x1, 0x14, 0x800};
    for (size_t k = 0; k < sizeof(masks) / sizeof(masks[0]); k++) {
        NSIndexSet *actual = [idx indicesForFlag:masks[k]];
        NSIndexSet *expected = referenceFlag(idx, masks[k]);
        PASS([actual isEqualToIndexSet:expected],
             "PO1 [%s]: indicesForFlag(0x%x) (actual=%@ expected=%@)",
             surface, masks[k], actual, expected);
    }

    NSIndexSet *unmapped = [idx indicesForUnmapped];
    PASS([unmapped isEqualToIndexSet:referenceFlag(idx, 0x4)],
         "PO1 [%s]: indicesForUnmapped == flag(0x4)", surface);
}

// ── In-memory surface (fallback path) ──────────────────────────────

static void testInMemorySurface(void)
{
    TTIOGenomicIndex *idx = makeInMemoryIndex();
    PASS(idx.count == 8, "PO1: in-memory fixture has 8 reads");
    runQueryBattery(idx, "in-memory");
}

// ── Disk-loaded surface (interned-id fast path) ────────────────────

static void testDiskLoadedSurface(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_po1_%d.h5", (int)getpid()];
    unlink([path fileSystemRepresentation]);

    TTIOGenomicIndex *original = makeInMemoryIndex();
    NSError *err = nil;

    id<TTIOStorageProvider> w = [[TTIOProviderRegistry sharedRegistry]
        openURL:path mode:TTIOStorageOpenModeCreate provider:@"hdf5" error:&err];
    PASS(w != nil, "PO1: HDF5 provider opens for write");
    id<TTIOStorageGroup> root = [w rootGroupWithError:&err];
    id<TTIOStorageGroup> idxGroup = [root createGroupNamed:@"genomic_index" error:&err];
    PASS([original writeToGroup:idxGroup error:&err], "PO1: writeToGroup succeeds");
    [w close];

    id<TTIOStorageProvider> r = [[TTIOProviderRegistry sharedRegistry]
        openURL:path mode:TTIOStorageOpenModeRead provider:@"hdf5" error:&err];
    id<TTIOStorageGroup> root2 = [r rootGroupWithError:&err];
    id<TTIOStorageGroup> idxGroup2 = [root2 openGroupNamed:@"genomic_index" error:&err];
    TTIOGenomicIndex *loaded = [TTIOGenomicIndex readFromGroup:idxGroup2 error:&err];
    PASS(loaded != nil, "PO1: readFromGroup loads disk index");
    PASS(loaded.count == 8, "PO1: disk-loaded index has 8 reads");

    runQueryBattery(loaded, "disk-loaded");

    [r close];
    unlink([path fileSystemRepresentation]);
}

void testGenomicIndexRegionQuery(void)
{
    testInMemorySurface();
    testDiskLoadedSurface();
}
