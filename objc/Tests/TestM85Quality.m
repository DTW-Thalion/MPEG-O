// TestM85Quality.m — v0.13 M85 Phase A.
//
// Objective-C normative tests for the clean-room QUALITY_BINNED
// genomic codec — fixed Illumina-8 8-bin Phred quantisation +
// 4-bit-packed bin indices, big-endian within byte, lossy by
// construction. Mirrors python/tests/test_m85_quality.py and locks
// the cross-language wire format via byte-exact fixture comparison
// against quality_{a,b,c,d}.bin.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOQuality.h"

#include <openssl/sha.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ── Bin / centre tables (kept duplicated in tests so we can compute
// expected lossy round-trip values without trusting the codec) ─────

static uint8_t expectedBinOf(uint8_t p)
{
    if (p <= 1)  return 0;
    if (p <= 9)  return 1;
    if (p <= 19) return 2;
    if (p <= 24) return 3;
    if (p <= 29) return 4;
    if (p <= 34) return 5;
    if (p <= 39) return 6;
    return 7;
}

static const uint8_t kCentres[8] = { 0, 5, 15, 22, 27, 32, 37, 40 };

static uint8_t expectedCentreOf(uint8_t p)
{
    return kCentres[expectedBinOf(p)];
}

// ── Fixture loader (walk upward from CWD looking for objc/Tests/Fixtures)

static NSString *fixtureDir(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSString *candidate = [[here
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            NSString *probe = [candidate stringByAppendingPathComponent:@"quality_a.bin"];
            if ([fm fileExistsAtPath:probe]) return candidate;
        }
        NSString *candidate2 = [[[here
                stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"];
        if ([fm fileExistsAtPath:candidate2 isDirectory:&isDir] && isDir) {
            NSString *probe = [candidate2 stringByAppendingPathComponent:@"quality_a.bin"];
            if ([fm fileExistsAtPath:probe]) return candidate2;
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

static NSData *loadFixture(NSString *name)
{
    NSString *dir = fixtureDir();
    if (!dir) return nil;
    NSString *path = [dir stringByAppendingPathComponent:name];
    return [NSData dataWithContentsOfFile:path];
}

// ── Hex-dump-on-fail helper ────────────────────────────────────────

static void compareDataDumpHexOnFail(NSData *got, NSData *want, const char *label)
{
    if ([got isEqualToData:want]) return;
    NSUInteger min = (got.length < want.length) ? got.length : want.length;
    NSUInteger firstDiff = (NSUInteger)-1;
    const uint8_t *g = got.bytes;
    const uint8_t *w = want.bytes;
    for (NSUInteger i = 0; i < min; i++) {
        if (g[i] != w[i]) { firstDiff = i; break; }
    }
    fprintf(stderr,
            "  %s mismatch: got=%lu want=%lu first diff @ %ld\n",
            label, (unsigned long)got.length, (unsigned long)want.length,
            (long)firstDiff);
    if (firstDiff != (NSUInteger)-1) {
        NSUInteger lo = (firstDiff > 8) ? firstDiff - 8 : 0;
        NSUInteger hi = (firstDiff + 8 < min) ? firstDiff + 8 : min;
        fprintf(stderr, "    got: ");
        for (NSUInteger i = lo; i < hi; i++)
            fprintf(stderr, "%02x ", g[i]);
        fprintf(stderr, "\n   want: ");
        for (NSUInteger i = lo; i < hi; i++)
            fprintf(stderr, "%02x ", w[i]);
        fprintf(stderr, "\n");
    }
}

static double monoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// ── Canonical vector builders (HANDOFF M85 §8) ─────────────────────

static NSData *vectorA(void)
{
    // 256 bytes = pure bin centres repeated 32 times.
    uint8_t buf[256];
    for (int i = 0; i < 256; i++) buf[i] = kCentres[i & 7];
    return [NSData dataWithBytes:buf length:256];
}

static NSData *vectorB(void)
{
    // 1024 bytes derived from SHA-256("ttio-quality-vector-b").
    static const char salt[] = "ttio-quality-vector-b";
    uint8_t seed[32];
    SHA256((const uint8_t *)salt, sizeof(salt) - 1, seed);
    uint8_t buf[1024];
    for (int i = 0; i < 1024; i++) {
        if (i < 512) buf[i] = (uint8_t)(30 + (seed[i & 31] % 11));
        else         buf[i] = (uint8_t)(15 + (seed[i & 31] % 16));
    }
    return [NSData dataWithBytes:buf length:1024];
}

static NSData *vectorC(void)
{
    static const uint8_t data_c[64] = {
        0,  1,
        2,  5,  9,
        10, 15, 19,
        20, 22, 24,
        25, 27, 29,
        30, 32, 34,
        35, 37, 39,
        40, 41, 50, 60, 93, 100, 200, 255,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22, 27, 32, 37, 40,
        0, 5, 15, 22,
    };
    return [NSData dataWithBytes:data_c length:64];
}

static NSData *vectorD(void)
{
    return [NSData data];
}

// ── Test #1: round-trip 256 bytes of pure bin centres ──────────────

static void testRoundTripPureCentres(void)
{
    NSData *data = vectorA();
    NSData *enc = TTIOQualityEncode(data);
    PASS(enc != nil, "M85: pure-centres encode succeeds");
    // 256 bytes -> 6 + 128 = 134 bytes.
    PASS(enc.length == 134,
         "M85: pure-centres wire size = 134 (got %lu)",
         (unsigned long)enc.length);

    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85: pure-centres decode succeeds");
    PASS([dec isEqualToData:data],
         "M85: pure-centres round-trip byte-exact (lossless because all inputs are bin centres)");
}

// ── Test #2: round-trip arbitrary Phred 0..49 → lossy mapping ──────

static void testRoundTripArbitraryPhred(void)
{
    uint8_t buf[50];
    for (int i = 0; i < 50; i++) buf[i] = (uint8_t)i;
    NSData *data = [NSData dataWithBytes:buf length:50];

    NSData *enc = TTIOQualityEncode(data);
    PASS(enc != nil, "M85: Phred 0..49 encode succeeds");
    PASS(enc.length == 6 + 25,
         "M85: Phred 0..49 wire size = 31 (got %lu)",
         (unsigned long)enc.length);

    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85: Phred 0..49 decode succeeds");

    uint8_t expected[50];
    for (int i = 0; i < 50; i++) expected[i] = expectedCentreOf(buf[i]);
    NSData *expectedData = [NSData dataWithBytes:expected length:50];
    PASS([dec isEqualToData:expectedData],
         "M85: Phred 0..49 lossy round-trip == expected bin centres");
}

// ── Test #3: clamped Phred (50, 60, 93, 100, 200, 255) → 40 ────────

static void testRoundTripClamped(void)
{
    static const uint8_t buf[6] = { 50, 60, 93, 100, 200, 255 };
    NSData *data = [NSData dataWithBytes:buf length:6];

    NSData *enc = TTIOQualityEncode(data);
    PASS(enc != nil, "M85: clamped encode succeeds");

    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85: clamped decode succeeds");

    uint8_t expected[6] = { 40, 40, 40, 40, 40, 40 };
    NSData *expectedData = [NSData dataWithBytes:expected length:6];
    PASS([dec isEqualToData:expectedData],
         "M85: clamped round-trip == 40 for every byte > 39");
}

// ── Test #4: round-trip empty ──────────────────────────────────────

static void testRoundTripEmpty(void)
{
    NSData *empty = [NSData data];
    NSData *enc = TTIOQualityEncode(empty);
    PASS(enc != nil, "M85: empty encode succeeds");
    PASS(enc.length == 6,
         "M85: empty wire size = 6 (got %lu)", (unsigned long)enc.length);

    // Header bytes: version=0, scheme=0, length=0.
    const uint8_t expectedHeader[6] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    PASS(memcmp(enc.bytes, expectedHeader, 6) == 0,
         "M85: empty header bytes = 00 00 00 00 00 00");

    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(enc, &err);
    PASS(dec != nil && err == nil && dec.length == 0,
         "M85: empty round-trips to empty");
}

// ── Test #5: single byte at each bin centre ────────────────────────

static void testRoundTripSingleCentre(void)
{
    for (int bin = 0; bin < 8; bin++) {
        const uint8_t centre = kCentres[bin];
        NSData *data = [NSData dataWithBytes:&centre length:1];
        NSData *enc = TTIOQualityEncode(data);
        PASS(enc.length == 7,
             "M85: single-centre Phred=%u wire size = 7 (got %lu)",
             (unsigned)centre, (unsigned long)enc.length);
        const uint8_t bodyByte = ((const uint8_t *)enc.bytes)[6];
        const uint8_t expectedBody = (uint8_t)(bin << 4);
        PASS(bodyByte == expectedBody,
             "M85: single-centre Phred=%u body byte = 0x%02x (got 0x%02x)",
             (unsigned)centre, (unsigned)expectedBody, (unsigned)bodyByte);

        NSError *err = nil;
        NSData *dec = TTIOQualityDecode(enc, &err);
        PASS([dec isEqualToData:data],
             "M85: single-centre Phred=%u round-trips byte-exact",
             (unsigned)centre);
    }
}

// ── Test #6: padding-tail patterns (1, 2, 3, 4 byte inputs) ────────

static void testPaddingTailPatterns(void)
{
    // b"\x05" -> bin 1 -> body byte 0x10
    {
        const uint8_t in[1] = { 0x05 };
        NSData *enc = TTIOQualityEncode([NSData dataWithBytes:in length:1]);
        PASS(enc.length == 7,
             "M85: pad-tail [05] wire size = 7 (got %lu)",
             (unsigned long)enc.length);
        PASS(((const uint8_t *)enc.bytes)[6] == 0x10,
             "M85: pad-tail [05] body byte = 0x10 (got 0x%02x)",
             (unsigned)((const uint8_t *)enc.bytes)[6]);
    }
    // b"\x05\x05" -> body byte 0x11
    {
        const uint8_t in[2] = { 0x05, 0x05 };
        NSData *enc = TTIOQualityEncode([NSData dataWithBytes:in length:2]);
        PASS(enc.length == 7,
             "M85: pad-tail [05 05] wire size = 7 (got %lu)",
             (unsigned long)enc.length);
        PASS(((const uint8_t *)enc.bytes)[6] == 0x11,
             "M85: pad-tail [05 05] body byte = 0x11 (got 0x%02x)",
             (unsigned)((const uint8_t *)enc.bytes)[6]);
    }
    // b"\x05\x05\x05" -> body bytes 0x11 0x10
    {
        const uint8_t in[3] = { 0x05, 0x05, 0x05 };
        NSData *enc = TTIOQualityEncode([NSData dataWithBytes:in length:3]);
        PASS(enc.length == 8,
             "M85: pad-tail [05 05 05] wire size = 8 (got %lu)",
             (unsigned long)enc.length);
        const uint8_t b0 = ((const uint8_t *)enc.bytes)[6];
        const uint8_t b1 = ((const uint8_t *)enc.bytes)[7];
        PASS(b0 == 0x11 && b1 == 0x10,
             "M85: pad-tail [05 05 05] body = 11 10 (got %02x %02x)",
             (unsigned)b0, (unsigned)b1);
    }
    // 4-byte input: b"\x05\x05\x05\x05" -> body bytes 0x11 0x11
    {
        const uint8_t in[4] = { 0x05, 0x05, 0x05, 0x05 };
        NSData *enc = TTIOQualityEncode([NSData dataWithBytes:in length:4]);
        PASS(enc.length == 8,
             "M85: pad-tail [05 05 05 05] wire size = 8 (got %lu)",
             (unsigned long)enc.length);
        const uint8_t b0 = ((const uint8_t *)enc.bytes)[6];
        const uint8_t b1 = ((const uint8_t *)enc.bytes)[7];
        PASS(b0 == 0x11 && b1 == 0x11,
             "M85: pad-tail [05 05 05 05] body = 11 11 (got %02x %02x)",
             (unsigned)b0, (unsigned)b1);
    }
}

// ── Test #7: compression ratio on 1 MiB random Phred (mod 41) ──────

static void testCompressionRatio(void)
{
    const NSUInteger n = 1u << 20;   // 1 MiB
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)data.mutableBytes;
    // Deterministic LCG so the test isn't seed-dependent.
    uint32_t s = 0xC0FFEEu;
    for (NSUInteger i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        p[i] = (uint8_t)(s % 41u);
    }

    NSData *enc = TTIOQualityEncode(data);
    PASS(enc != nil, "M85: 1 MiB random Phred encode succeeds");
    PASS(enc.length == 6 + 524288,
         "M85: 1 MiB random Phred wire size = 524294 (got %lu)",
         (unsigned long)enc.length);
}

// ── Tests #8–#11: canonical-vector byte-exact conformance ──────────

static void testCanonicalVectorA(void)
{
    NSData *fixture = loadFixture(@"quality_a.bin");
    PASS(fixture != nil, "M85: quality_a.bin fixture loads");
    PASS(fixture.length == 134,
         "M85: vector A fixture length = 134 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIOQualityEncode(vectorA());
    compareDataDumpHexOnFail(enc, fixture, "vector A");
    PASS([enc isEqualToData:fixture],
         "M85: vector A byte-exact match against Python fixture");
    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(fixture, &err);
    PASS([dec isEqualToData:vectorA()],
         "M85: vector A fixture decodes back to vector A (centres are lossless)");
}

static void testCanonicalVectorB(void)
{
    NSData *fixture = loadFixture(@"quality_b.bin");
    PASS(fixture != nil, "M85: quality_b.bin fixture loads");
    PASS(fixture.length == 518,
         "M85: vector B fixture length = 518 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIOQualityEncode(vectorB());
    compareDataDumpHexOnFail(enc, fixture, "vector B");
    PASS([enc isEqualToData:fixture],
         "M85: vector B byte-exact match against Python fixture");
}

static void testCanonicalVectorC(void)
{
    NSData *fixture = loadFixture(@"quality_c.bin");
    PASS(fixture != nil, "M85: quality_c.bin fixture loads");
    PASS(fixture.length == 38,
         "M85: vector C fixture length = 38 (got %lu)",
         (unsigned long)fixture.length);
    NSData *data = vectorC();
    PASS(data.length == 64,
         "M85: vector C input length = 64 (got %lu)",
         (unsigned long)data.length);
    NSData *enc = TTIOQualityEncode(data);
    compareDataDumpHexOnFail(enc, fixture, "vector C");
    PASS([enc isEqualToData:fixture],
         "M85: vector C byte-exact match against Python fixture");

    // Also check the lossy round-trip matches per-byte centres.
    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(fixture, &err);
    PASS(dec != nil && err == nil, "M85: vector C fixture decodes");
    NSMutableData *expected = [NSMutableData dataWithLength:64];
    uint8_t *e = (uint8_t *)expected.mutableBytes;
    const uint8_t *src = (const uint8_t *)data.bytes;
    for (int i = 0; i < 64; i++) e[i] = expectedCentreOf(src[i]);
    PASS([dec isEqualToData:expected],
         "M85: vector C lossy decode == per-byte bin centres");
}

static void testCanonicalVectorD(void)
{
    NSData *fixture = loadFixture(@"quality_d.bin");
    PASS(fixture != nil, "M85: quality_d.bin fixture loads");
    PASS(fixture.length == 6,
         "M85: vector D fixture length = 6 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIOQualityEncode(vectorD());
    PASS([enc isEqualToData:fixture],
         "M85: vector D byte-exact match against Python fixture");
}

// ── Test #12: malformed input handling ─────────────────────────────

static void testDecodeMalformed(void)
{
    NSError *err = nil;

    // (a) Stream shorter than 6 bytes (3 bytes).
    {
        const uint8_t buf[3] = { 0x00, 0x00, 0x00 };
        NSData *bad = [NSData dataWithBytes:buf length:3];
        err = nil;
        PASS(TTIOQualityDecode(bad, &err) == nil && err != nil,
             "M85: short stream (3 bytes) -> nil + error");
    }

    // Build a known-good "encode \x05\x05\x05" stream (orig=3,
    // body=2, total=8) we can mutate.
    const uint8_t goodIn[3] = { 0x05, 0x05, 0x05 };
    NSData *good = TTIOQualityEncode([NSData dataWithBytes:goodIn length:3]);

    // (b) Bad version byte (0x01 instead of 0x00).
    {
        NSMutableData *badVer = [good mutableCopy];
        ((uint8_t *)badVer.mutableBytes)[0] = 0x01;
        err = nil;
        PASS(TTIOQualityDecode(badVer, &err) == nil && err != nil,
             "M85: bad version byte -> nil + error");
    }

    // (c) Bad scheme_id (0xFF instead of 0x00).
    {
        NSMutableData *badScheme = [good mutableCopy];
        ((uint8_t *)badScheme.mutableBytes)[1] = 0xFF;
        err = nil;
        PASS(TTIOQualityDecode(badScheme, &err) == nil && err != nil,
             "M85: bad scheme_id -> nil + error");
    }

    // (d) original_length says 4 but body is 5 bytes.
    // Header: version=0, scheme=0, orig_len=4 (BE) ; body 5 bytes
    // total = 11 instead of expected 6 + ceil(4/2)=8.
    {
        const uint8_t bad[11] = {
            0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x00, 0x00,
        };
        NSData *badLen = [NSData dataWithBytes:bad length:11];
        err = nil;
        PASS(TTIOQualityDecode(badLen, &err) == nil && err != nil,
             "M85: orig_len says 4 but body is 5 -> nil + error");
    }

    // (e) original_length says 5 but body is only 2 bytes.
    // total = 8 instead of expected 6 + ceil(5/2)=9.
    {
        const uint8_t bad[8] = {
            0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
            0x00, 0x00,
        };
        NSData *badLen = [NSData dataWithBytes:bad length:8];
        err = nil;
        PASS(TTIOQualityDecode(badLen, &err) == nil && err != nil,
             "M85: orig_len says 5 but body is only 2 -> nil + error");
    }

    PASS(YES, "M85: malformed-input decoding completes without crash");
}

// ── Test #13: throughput ───────────────────────────────────────────

static void testThroughput(void)
{
    const NSUInteger n = 4u << 20;   // 4 MiB random Phred (mod 41)
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)data.mutableBytes;
    uint32_t s = 0xDEADBEEFu;
    for (NSUInteger i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        p[i] = (uint8_t)(s % 41u);
    }

    double t0 = monoSeconds();
    NSData *enc = TTIOQualityEncode(data);
    double tEnc = monoSeconds() - t0;

    double t1 = monoSeconds();
    NSError *err = nil;
    NSData *dec = TTIOQualityDecode(enc, &err);
    double tDec = monoSeconds() - t1;

    double mb = (double)n / (1024.0 * 1024.0);
    double encMBs = (tEnc > 0.0) ? (mb / tEnc) : 0.0;
    double decMBs = (tDec > 0.0) ? (mb / tDec) : 0.0;
    fprintf(stderr,
            "  M85 throughput (4 MiB random Phred mod 41): "
            "encode %.1f MB/s (%.3fs), decode %.1f MB/s (%.3fs)\n",
            encMBs, tEnc, decMBs, tDec);

    PASS(dec != nil && err == nil && dec.length == n,
         "M85: throughput decode produces n=4 MiB output");

    // Verify lossy correctness on the first 1024 bytes (full check
    // would dominate the benchmark; spot-check is enough).
    const uint8_t *got = (const uint8_t *)dec.bytes;
    BOOL spotOK = YES;
    for (NSUInteger i = 0; i < 1024 && spotOK; i++) {
        if (got[i] != expectedCentreOf(p[i])) spotOK = NO;
    }
    PASS(spotOK, "M85: throughput first-1024 bytes match expected centres");

    // Hard floors per HANDOFF M85 §8.2: encode >= 150 MB/s,
    // decode >= 250 MB/s. Soft targets 300 / 500.
    PASS(encMBs >= 150.0,
         "M85: encode throughput >= 150 MB/s hard floor (got %.1f MB/s, soft target 300)",
         encMBs);
    PASS(decMBs >= 250.0,
         "M85: decode throughput >= 250 MB/s hard floor (got %.1f MB/s, soft target 500)",
         decMBs);
}

// ── Public entry point ─────────────────────────────────────────────

void testM85Quality(void);
void testM85Quality(void)
{
    testRoundTripPureCentres();
    testRoundTripArbitraryPhred();
    testRoundTripClamped();
    testRoundTripEmpty();
    testRoundTripSingleCentre();
    testPaddingTailPatterns();
    testCompressionRatio();
    testCanonicalVectorA();
    testCanonicalVectorB();
    testCanonicalVectorC();
    testCanonicalVectorD();
    testDecodeMalformed();
    testThroughput();
}
