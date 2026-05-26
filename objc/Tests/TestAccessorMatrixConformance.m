/*
 * TestAccessorMatrixConformance.m — Task 3.10 of transport-spec v0.11.
 *
 * For each TTIOAccessorSpec entry: builds a fixture .tio containing
 * only that accessor's content, round-trips it through
 * TTIOTransportWriter -writeDataset: -> TTIOTransportReader
 * -writeTtioToPath:, then asserts content equality via the accessor's
 * matcher.
 *
 * Cross-language equivalents:
 *   Java   AccessorMatrixConformanceTest  (commit 46c26587)
 *   Python tests/test_accessor_matrix_conformance.py
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include <unistd.h>

#import "TTIOAccessorSpec.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"

static NSString *amcTempPath(NSString *prefix, NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_amc_%d_%@_%@",
                       (int)getpid(), prefix, suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static void amcRm(NSString *p)
{
    if (p) unlink([p fileSystemRepresentation]);
}

// Build a stable C-string label "3.10 amc[<NAME>]: <suffix>" for PASS
// macros. The PASS macro requires a literal format string, so we
// embed everything into a single %s argument.
static const char *amcLabel(NSString *name, NSString *suffix)
{
    NSString *s = [NSString stringWithFormat:@"3.10 amc[%@]: %@",
                    name, suffix];
    return [s UTF8String];
}

static void runOneAccessor(TTIOAccessorSpec *spec)
{
    NSString *src = amcTempPath(spec.name, @"src.tio");
    NSString *tis = amcTempPath(spec.name, @"stream.tis");
    NSString *rt  = amcTempPath(spec.name, @"rt.tio");
    amcRm(src); amcRm(tis); amcRm(rt);

    NSError *err = nil;
    BOOL ok = spec.build(src, &err);
    PASS((ok && err == nil), "%s", amcLabel(spec.name, @"fixture built"));
    if (!ok) {
        NSLog(@"  build error: %@", err);
        amcRm(src); amcRm(tis); amcRm(rt);
        return;
    }

    // .tio -> .tis
    TTIOSpectralDataset *source =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS((source != nil), "%s", amcLabel(spec.name, @"source dataset opens"));

    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithOutputPath:tis];
    BOOL wrote = [w writeDataset:source error:&err];
    [w close];
    PASS((wrote && err == nil), "%s",
         amcLabel(spec.name, @"writeDataset emitted .tis"));

    [source closeFile];

    // .tis -> .tio
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithInputPath:tis];
    err = nil;
    BOOL materialised = [r writeTtioToPath:rt error:&err];
    PASS((materialised && err == nil), "%s",
         amcLabel(spec.name, @"writeTtioToPath materialised"));

    // Re-open both and compare via the accessor's matcher.
    TTIOSpectralDataset *a =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOSpectralDataset *b =
        [TTIOSpectralDataset readFromFilePath:rt error:&err];
    PASS((a != nil && b != nil), "%s",
         amcLabel(spec.name, @"both ends re-open"));

    NSString *mismatch = spec.assertEqual(a, b);
    NSString *suffix = mismatch != nil
        ? [NSString stringWithFormat:@"round-trip preserves accessor (%@)", mismatch]
        : @"round-trip preserves accessor";
    PASS((mismatch == nil), "%s", amcLabel(spec.name, suffix));

    [a closeFile];
    [b closeFile];
    amcRm(src); amcRm(tis); amcRm(rt);
}

void testAccessorMatrixConformance(void);
void testAccessorMatrixConformance(void)
{
    NSArray<TTIOAccessorSpec *> *specs = TTIOAccessorSpecsAll();
    PASS((specs.count >= 7),
         "3.10 amc: AccessorSpec list is non-empty (>=7 entries)");
    for (TTIOAccessorSpec *spec in specs) {
        runOneAccessor(spec);
    }
}
