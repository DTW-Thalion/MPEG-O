/*
 * TestCoverageGapWatchdog.m — Task 3.10 of transport-spec v0.11.
 *
 * Crude-but-effective floor: the .tis byte size MUST be at least 1%
 * of the source .tio byte size. If a writer silently drops a content
 * type, this test fires immediately.
 *
 * Wired against the `everything.tio` fixture that exercises every
 * first-class v0.11 accessor at once. A second test method
 * additionally asserts the .tis round-trips back to a .tio whose
 * contents match the source across every TTIOAccessorSpec — the
 * strongest coverage guarantee Task 3.10 can express.
 *
 * Stage 6 (Task 6.6, Deferral 2): SUBJECTS + SAMPLES are now
 * populated by +buildEverythingAtPath: and exercised by both
 * watchdog methods.
 *
 * Cross-language equivalents:
 *   Java   CoverageGapWatchdogTest  (commit 2d04e035)
 *   Python tests/test_coverage_gap_watchdog.py (commit 57037d82)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include <unistd.h>
#include <sys/stat.h>

#import "TTIOAccessorSpec.h"
#import "TTIOV011FixtureBuilder.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"

static NSString *cgwTempPath(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_cgw_%d_%@",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static void cgwRm(NSString *p)
{
    if (p) unlink([p fileSystemRepresentation]);
}

static long long cgwFileSize(NSString *path)
{
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) return -1;
    return (long long)st.st_size;
}

// ── 1. .tis size at least 1% of .tio on the everything fixture ──────

static void testTisSizeAtLeastOnePercentOfTio(void)
{
    NSString *src = cgwTempPath(@"everything.tio");
    NSString *tis = cgwTempPath(@"everything.tis");
    cgwRm(src); cgwRm(tis);

    NSError *err = nil;
    BOOL built = [TTIOV011FixtureBuilder buildEverythingAtPath:src
                                                          error:&err];
    PASS(built && err == nil,
         "3.10 cgw: everything.tio fixture built");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.10 cgw: everything.tio opened");

    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithOutputPath:tis];
    BOOL wrote = [w writeDataset:ds error:&err];
    [w close];
    PASS(wrote && err == nil,
         "3.10 cgw: writeDataset emitted everything.tis");
    [ds closeFile];

    long long srcSize = cgwFileSize(src);
    long long tisSize = cgwFileSize(tis);
    PASS(srcSize > 0 && tisSize > 0,
         "3.10 cgw: both files have positive size");
    NSLog(@"  [3.10 cgw] .tio=%lld bytes, .tis=%lld bytes, ratio=%.2f%%",
          srcSize, tisSize,
          srcSize > 0 ? (100.0 * (double)tisSize / (double)srcSize) : 0.0);
    PASS(tisSize > srcSize / 100,
         "3.10 cgw: .tis > 1%% of .tio (rules out silent drop)");

    cgwRm(src); cgwRm(tis);
}

// ── 2. everything fixture round-trips every accessor ────────────────

static void testEverythingFixtureRoundTripsEveryAccessor(void)
{
    NSString *src = cgwTempPath(@"all.tio");
    NSString *tis = cgwTempPath(@"all.tis");
    NSString *rt  = cgwTempPath(@"all_rt.tio");
    cgwRm(src); cgwRm(tis); cgwRm(rt);

    NSError *err = nil;
    BOOL built = [TTIOV011FixtureBuilder buildEverythingAtPath:src
                                                          error:&err];
    PASS(built && err == nil,
         "3.10 cgw rt: everything.tio fixture built");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.10 cgw rt: everything.tio opened");
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithOutputPath:tis];
    BOOL wrote = [w writeDataset:ds error:&err];
    [w close];
    PASS(wrote && err == nil,
         "3.10 cgw rt: writeDataset emitted everything.tis");
    [ds closeFile];

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithInputPath:tis];
    err = nil;
    BOOL materialised = [r writeTtioToPath:rt error:&err];
    PASS(materialised && err == nil,
         "3.10 cgw rt: writeTtioToPath materialised");

    TTIOSpectralDataset *a =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOSpectralDataset *b =
        [TTIOSpectralDataset readFromFilePath:rt error:&err];
    PASS(a != nil && b != nil,
         "3.10 cgw rt: both ends re-open");

    // Stage 5 (Task 5.6) accessors are intentionally not populated by
    // +buildEverythingAtPath: MS_IMAGE_PROCESSED is a wire-mode
    // override of the same MSImage already covered by IMAGE;
    // RAMAN_IMAGE / IR_IMAGE are first-class siblings of MSImage on
    // TTIOSpectralDataset that the v0.11 everything fixture does not
    // yet include. The per-accessor conformance suite still exercises
    // all three.
    NSSet<NSString *> *stage5Skip = [NSSet setWithArray:@[
        @"MS_IMAGE_PROCESSED", @"RAMAN_IMAGE", @"IR_IMAGE",
    ]];
    NSArray<TTIOAccessorSpec *> *specs = TTIOAccessorSpecsAll();
    for (TTIOAccessorSpec *spec in specs) {
        if ([stage5Skip containsObject:spec.name]) continue;
        NSString *mismatch = nil;
        NS_DURING
            mismatch = spec.assertEqual(a, b);
        NS_HANDLER
            mismatch = [NSString stringWithFormat:@"exception: %@",
                         [localException reason]];
        NS_ENDHANDLER
        NSString *label = mismatch != nil
            ? [NSString stringWithFormat:
                @"3.10 cgw rt: %@ preserved in everything fixture (%@)",
                spec.name, mismatch]
            : [NSString stringWithFormat:
                @"3.10 cgw rt: %@ preserved in everything fixture",
                spec.name];
        PASS((mismatch == nil), "%s", [label UTF8String]);
    }

    [a closeFile];
    [b closeFile];
    cgwRm(src); cgwRm(tis); cgwRm(rt);
}

void testCoverageGapWatchdog(void);
void testCoverageGapWatchdog(void)
{
    testTisSizeAtLeastOnePercentOfTio();
    testEverythingFixtureRoundTripsEveryAccessor();
}
