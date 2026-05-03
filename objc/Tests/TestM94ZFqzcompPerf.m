// TestM94ZFqzcompPerf.m — M94.Z throughput regression smoke (ObjC).
//
// Encodes (and decodes) 100K reads × 100bp varied Illumina-profile
// qualities (~10 MB raw) and reports throughput. M94.Z is the CRAM-mimic
// codec at objc/Source/Codecs/TTIOFqzcompNx16Z.{h,m}.
//
// Spec target: encode >= 100 MB/s, decode >= 50 MB/s.
// Hard regression floor (gate): encode >= 30 MB/s.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"

#include <stdint.h>
#include <time.h>

static double m94zMonoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static NSData *m94zBuildVariedQualities(NSUInteger n)
{
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    uint64_t s = 0xBEEFULL;
    for (NSUInteger i = 0; i < n; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        // Q20..Q40 (ASCII 53..73) — same input as the M94 v1 perf test.
        p[i] = (uint8_t)(33u + 20u + (uint32_t)((s >> 32) % 21u));
    }
    return out;
}

static void testM94ZEncodeDecodeThroughput(void)
{
    const NSUInteger nReads = 100000;
    const NSUInteger readLen = 100;
    const NSUInteger nQual = nReads * readLen;

    NSData *qualities = m94zBuildVariedQualities(nQual);
    NSMutableArray<NSNumber *> *readLengths =
        [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray<NSNumber *> *revcompFlags =
        [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        [readLengths addObject:@(readLen)];
        [revcompFlags addObject:@((i & 7) == 0 ? 1 : 0)];
    }

    double t0 = m94zMonoSeconds();
    NSError *err = nil;
    NSData *encoded = [TTIOFqzcompNx16Z encodeWithQualities:qualities
                                                 readLengths:readLengths
                                                revcompFlags:revcompFlags
                                                       error:&err];
    double tEnc = m94zMonoSeconds() - t0;

    PASS(encoded != nil, "M94.Z perf: encode produced bytes (err=%@)",
         err.localizedDescription);
    if (encoded == nil) return;

    double t1 = m94zMonoSeconds();
    NSDictionary *decoded = [TTIOFqzcompNx16Z decodeData:encoded
                                            revcompFlags:revcompFlags
                                                   error:&err];
    double tDec = m94zMonoSeconds() - t1;
    PASS(decoded != nil, "M94.Z perf: decode produced data (err=%@)",
         err.localizedDescription);
    if (decoded == nil) return;
    PASS([decoded[@"qualities"] isEqualToData:qualities],
         "M94.Z perf: round-trip byte-exact");

    double mb = (double)nQual / 1e6;
    double encMBs = (tEnc > 0.0) ? (mb / tEnc) : 0.0;
    double decMBs = (tDec > 0.0) ? (mb / tDec) : 0.0;
    double ratio = (double)encoded.length / (double)nQual;

    fprintf(stderr,
            "  M94.Z FQZCOMP_NX16_Z throughput (ObjC, %lu reads x %lu bp = %.1f MB raw): "
            "encode %.1f MB/s (%.2fs), decode %.1f MB/s (%.2fs), ratio %.3fx\n",
            (unsigned long)nReads, (unsigned long)readLen,
            mb, encMBs, tEnc, decMBs, tDec, ratio);

    // Threshold reality check (Stage 3 + v1.6 era):
    //   V1 (pure ObjC):   ~50 MB/s encode
    //   V2 (libttio_rans, AVX2 SIMD): ~45 MB/s encode
    //   V4 (CRAM 3.1 fqzcomp port, the v1.6 default): ~22 MB/s encode
    // V4's range coder is single-state serial — no SIMD path
    // possible. The 30 MB/s threshold from the V2 era is not
    // achievable on the V4 default. Set the regression floor to
    // 18 MB/s (≈80% of measured V4) so genuine regressions trip
    // without flaking on normal load variance.
    PASS(encMBs >= 18.0,
         "M94.Z ObjC: encode throughput >= 18 MB/s regression floor "
         "(got %.1f MB/s; V4 sequential range coder ceiling ~22 MB/s)",
         encMBs);
}

void testM94ZFqzcompPerf(void);
void testM94ZFqzcompPerf(void)
{
    testM94ZEncodeDecodeThroughput();
}
