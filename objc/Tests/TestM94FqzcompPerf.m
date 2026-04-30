// TestM94FqzcompPerf.m — v1.2 M94 throughput regression smoke (ObjC).
//
// Encodes 100K reads × 100bp varied Illumina-profile qualities (~10 MB
// raw) and asserts encode throughput. Mirrors python/tests/perf/
// test_m94_throughput.py and java/.../FqzcompNx16PerfTest.java.
//
// Spec target (§11): ≥100 MB/s native ObjC encode.
// Hard regression floor (this gate): ≥30 MB/s.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16.h"
#include <stdint.h>
#include <time.h>

// CLOCK_MONOTONIC works on both Linux GNUstep and macOS (≥10.12).
static double monoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static NSData *_buildVariedQualities(NSUInteger n)
{
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    uint64_t s = 0xBEEFULL;
    for (NSUInteger i = 0; i < n; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        // Q20..Q40 (ASCII 53..73) — varied so adaptive freq tables
        // produce non-trivial divergence (mirrors Python + Java perf).
        p[i] = (uint8_t)(33u + 20u + (uint32_t)((s >> 32) % 21u));
    }
    return out;
}

static void testEncodeThroughput(void)
{
    const NSUInteger nReads = 100000;
    const NSUInteger readLen = 100;
    const NSUInteger nQual = nReads * readLen;

    NSData *qualities = _buildVariedQualities(nQual);
    NSMutableArray<NSNumber *> *readLengths = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray<NSNumber *> *revcompFlags = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        [readLengths addObject:@(readLen)];
        [revcompFlags addObject:@((i & 7) == 0 ? 1 : 0)];  // ~12.5% revcomp
    }

    double t0 = monoSeconds();
    NSError *err = nil;
    NSData *encoded = [TTIOFqzcompNx16 encodeWithQualities:qualities
                                               readLengths:readLengths
                                              revcompFlags:revcompFlags
                                                     error:&err];
    double tEnc = monoSeconds() - t0;

    PASS(encoded != nil, "M94 perf: encode produced bytes (err=%@)",
         err.localizedDescription);
    if (encoded == nil) return;

    double mb = (double)nQual / 1e6;
    double encMBs = (tEnc > 0.0) ? (mb / tEnc) : 0.0;
    double ratio = (double)encoded.length / (double)nQual;

    fprintf(stderr,
            "  M94 FQZCOMP_NX16 throughput (ObjC, %lu reads x %lu bp = %.1f MB raw): "
            "encode %.1f MB/s (%.2fs), ratio %.3fx\n",
            (unsigned long)nReads, (unsigned long)readLen,
            mb, encMBs, tEnc, ratio);

    PASS(encMBs >= 30.0,
         "M94 ObjC: encode throughput >= 30 MB/s regression floor "
         "(got %.1f MB/s, spec target 100 MB/s)",
         encMBs);
}

void testM94FqzcompPerf(void);
void testM94FqzcompPerf(void)
{
    testEncodeThroughput();
}
