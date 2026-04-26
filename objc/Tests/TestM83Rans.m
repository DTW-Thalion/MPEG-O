// TestM83Rans.m — v0.13 M83.
//
// Objective-C normative tests for the clean-room rANS entropy codec.
// Mirrors python/tests/test_m83_rans.py and locks the cross-language
// wire format via byte-exact fixture comparison.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIORans.h"

#include <openssl/sha.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
            // confirm it has at least one rans_*.bin so we don't pick a
            // wrong Tests/Fixtures higher up.
            NSString *probe = [candidate stringByAppendingPathComponent:@"rans_a_o0.bin"];
            if ([fm fileExistsAtPath:probe]) return candidate;
        }
        // Also try a sibling objc/Tests/Fixtures (when CWD is repo root).
        NSString *candidate2 = [[[here
                stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"];
        if ([fm fileExistsAtPath:candidate2 isDirectory:&isDir] && isDir) {
            NSString *probe = [candidate2 stringByAppendingPathComponent:@"rans_a_o0.bin"];
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

// ── Canonical vector builders (HANDOFF.md §6.1) ────────────────────

static NSData *vectorA(void)
{
    // SHA-256 of "ttio-rans-test-vector-a", repeated 8 times = 256 bytes.
    const char salt[] = "ttio-rans-test-vector-a";
    uint8_t digest[32];
    SHA256((const uint8_t *)salt, sizeof(salt) - 1, digest);
    NSMutableData *out = [NSMutableData dataWithCapacity:256];
    for (int i = 0; i < 8; i++) [out appendBytes:digest length:32];
    return out;
}

static NSData *vectorB(void)
{
    // 800 × 0x00 + 100 × 0x01 + 80 × 0x02 + 44 × 0x03 = 1024 bytes.
    NSMutableData *out = [NSMutableData dataWithLength:1024];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    memset(p, 0, 800);
    memset(p + 800, 1, 100);
    memset(p + 900, 2, 80);
    memset(p + 980, 3, 44);
    return out;
}

static NSData *vectorC(void)
{
    // 0,1,2,3,0,1,2,3,... × 128 = 512 bytes.
    NSMutableData *out = [NSMutableData dataWithLength:512];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    for (int i = 0; i < 512; i++) p[i] = (uint8_t)(i % 4);
    return out;
}

// ── Helpers ────────────────────────────────────────────────────────

static NSData *randomData(NSUInteger n, unsigned int seed)
{
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    // Linear congruential filler — deterministic per seed but not
    // patterned in any way the codec is sensitive to.  The codec only
    // sees byte values, so this is plenty random for round-trip tests.
    uint32_t state = seed ? seed : 0xDEADBEEFu;
    for (NSUInteger i = 0; i < n; i++) {
        state = state * 1664525u + 1013904223u;
        p[i] = (uint8_t)((state >> 16) & 0xFF);
    }
    return out;
}

static NSData *biasedData(NSUInteger n)
{
    // 90% 0x00, 5% 0x01, 3% 0x02, 2% 0x03 — block layout, same shape
    // as the Python test (counts are deterministic given n).
    NSUInteger c0 = (NSUInteger)((double)n * 0.90);
    NSUInteger c1 = (NSUInteger)((double)n * 0.05);
    NSUInteger c2 = (NSUInteger)((double)n * 0.03);
    NSUInteger c3 = (n > c0 + c1 + c2) ? (n - c0 - c1 - c2) : 0;
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    NSUInteger pos = 0;
    memset(p + pos, 0, c0); pos += c0;
    memset(p + pos, 1, c1); pos += c1;
    memset(p + pos, 2, c2); pos += c2;
    memset(p + pos, 3, c3);
    return out;
}

static double monoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// ── Tests #1–#6: round-trip ────────────────────────────────────────

static void testRoundTripRandomOrder0(void)
{
    NSData *data = randomData(1u << 20, 1);
    NSData *enc = TTIORansEncode(data, 0);
    PASS(enc != nil, "M83: order-0 1MB random encode succeeds");
    PASS(enc.length > 0,
         "M83: order-0 1MB random encode emits bytes");
    NSError *err = nil;
    NSData *dec = TTIORansDecode(enc, &err);
    PASS(dec != nil, "M83: order-0 1MB random decode succeeds");
    PASS([dec isEqualToData:data],
         "M83: order-0 1MB random round-trips byte-exact");
}

static void testRoundTripRandomOrder1(void)
{
    NSData *data = randomData(1u << 20, 2);
    NSData *enc = TTIORansEncode(data, 1);
    PASS(enc != nil, "M83: order-1 1MB random encode succeeds");
    NSError *err = nil;
    NSData *dec = TTIORansDecode(enc, &err);
    PASS(dec != nil, "M83: order-1 1MB random decode succeeds");
    PASS([dec isEqualToData:data],
         "M83: order-1 1MB random round-trips byte-exact");
}

static void testRoundTripBiasedOrder0(void)
{
    NSData *data = biasedData(1u << 20);
    NSData *enc = TTIORansEncode(data, 0);
    PASS(enc != nil, "M83: order-0 1MB biased encode succeeds");
    PASS(enc.length < (1u << 19),
         "M83: order-0 1MB biased compresses to < 0.5 MB (got %lu)",
         (unsigned long)enc.length);
    NSError *err = nil;
    NSData *dec = TTIORansDecode(enc, &err);
    PASS([dec isEqualToData:data],
         "M83: order-0 1MB biased round-trips byte-exact");
}

static void testRoundTripAllIdentical(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:1u << 20];
    memset(data.mutableBytes, 0x41, data.length);
    NSData *enc = TTIORansEncode(data, 0);
    PASS(enc != nil, "M83: all-identical encode succeeds");
    PASS(enc.length < 10 * 1024,
         "M83: 1 MB of 0x41 compresses to < 10 KB (got %lu)",
         (unsigned long)enc.length);
    NSError *err = nil;
    NSData *dec = TTIORansDecode(enc, &err);
    PASS([dec isEqualToData:data],
         "M83: all-identical round-trips byte-exact");
}

static void testRoundTripEmpty(void)
{
    for (int order = 0; order <= 1; order++) {
        NSData *enc = TTIORansEncode([NSData data], order);
        PASS(enc != nil && enc.length >= 9,
             "M83: empty order-%d encode produces >= 9 byte stream", order);
        NSError *err = nil;
        NSData *dec = TTIORansDecode(enc, &err);
        PASS(dec != nil && dec.length == 0,
             "M83: empty order-%d round-trips to empty", order);
    }
}

static void testRoundTripSingleByte(void)
{
    uint8_t b = 0x42;
    NSData *data = [NSData dataWithBytes:&b length:1];
    for (int order = 0; order <= 1; order++) {
        NSData *enc = TTIORansEncode(data, order);
        PASS(enc != nil, "M83: single-byte order-%d encode succeeds", order);
        NSError *err = nil;
        NSData *dec = TTIORansDecode(enc, &err);
        PASS([dec isEqualToData:data],
             "M83: single-byte order-%d round-trips byte-exact", order);
    }
}

// ── Tests #7–#10: canonical-vector byte-exact conformance ──────────

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

static void testCanonicalVectorAOrder0(void)
{
    NSData *fixture = loadFixture(@"rans_a_o0.bin");
    PASS(fixture != nil, "M83: rans_a_o0.bin fixture loads");
    NSData *data = vectorA();
    NSData *enc = TTIORansEncode(data, 0);
    compareDataDumpHexOnFail(enc, fixture, "vector A o0");
    PASS([enc isEqualToData:fixture],
         "M83: vector A order-0 byte-exact match against Python fixture");
    NSError *err = nil;
    NSData *dec = TTIORansDecode(fixture, &err);
    PASS([dec isEqualToData:data],
         "M83: vector A order-0 fixture decodes back to vector A");
}

static void testCanonicalVectorBOrder0(void)
{
    NSData *fixture = loadFixture(@"rans_b_o0.bin");
    PASS(fixture != nil, "M83: rans_b_o0.bin fixture loads");
    NSData *data = vectorB();
    NSData *enc = TTIORansEncode(data, 0);
    compareDataDumpHexOnFail(enc, fixture, "vector B o0");
    PASS([enc isEqualToData:fixture],
         "M83: vector B order-0 byte-exact match against Python fixture");
    // Spec: payload portion (after 9-byte header + 1024-byte freq table)
    // is < 300 bytes for the heavily skewed input.
    const uint8_t *p = enc.bytes;
    uint32_t payload_len = ((uint32_t)p[5] << 24) | ((uint32_t)p[6] << 16) |
                           ((uint32_t)p[7] <<  8) | ((uint32_t)p[8]);
    PASS(payload_len < 300,
         "M83: vector B order-0 payload < 300 bytes (got %u)", payload_len);
}

static void testCanonicalVectorCOrder0(void)
{
    NSData *fixture = loadFixture(@"rans_c_o0.bin");
    PASS(fixture != nil, "M83: rans_c_o0.bin fixture loads");
    NSData *data = vectorC();
    NSData *enc = TTIORansEncode(data, 0);
    compareDataDumpHexOnFail(enc, fixture, "vector C o0");
    PASS([enc isEqualToData:fixture],
         "M83: vector C order-0 byte-exact match against Python fixture");
}

static void testCanonicalVectorCOrder1(void)
{
    NSData *fixture0 = loadFixture(@"rans_c_o0.bin");
    NSData *fixture1 = loadFixture(@"rans_c_o1.bin");
    PASS(fixture1 != nil, "M83: rans_c_o1.bin fixture loads");
    NSData *data = vectorC();
    NSData *enc1 = TTIORansEncode(data, 1);
    compareDataDumpHexOnFail(enc1, fixture1, "vector C o1");
    PASS([enc1 isEqualToData:fixture1],
         "M83: vector C order-1 byte-exact match against Python fixture");
    PASS(fixture1.length < fixture0.length,
         "M83: vector C order-1 (%lu) beats order-0 (%lu) on cyclic data",
         (unsigned long)fixture1.length, (unsigned long)fixture0.length);
    NSError *err = nil;
    NSData *dec = TTIORansDecode(fixture1, &err);
    PASS([dec isEqualToData:data],
         "M83: vector C order-1 fixture decodes back to vector C");
}

// ── Test #11: malformed input handling ─────────────────────────────

static void testDecodeMalformed(void)
{
    NSError *err = nil;

    // Empty input.
    err = nil;
    PASS(TTIORansDecode([NSData data], &err) == nil && err != nil,
         "M83: empty input → nil + error (no crash)");

    // Shorter than header.
    err = nil;
    uint8_t tiny[3] = {0, 0, 0};
    NSData *t1 = [NSData dataWithBytes:tiny length:3];
    PASS(TTIORansDecode(t1, &err) == nil && err != nil,
         "M83: 3-byte input → nil + error");

    // Bogus order byte.
    NSData *good = TTIORansEncode([@"hello world" dataUsingEncoding:NSASCIIStringEncoding], 0);
    NSMutableData *badOrder = [good mutableCopy];
    ((uint8_t *)badOrder.mutableBytes)[0] = 0x05;
    err = nil;
    PASS(TTIORansDecode(badOrder, &err) == nil && err != nil,
         "M83: bogus order byte → nil + error");

    // Truncated payload.
    NSData *truncated = [good subdataWithRange:NSMakeRange(0, good.length - 4)];
    err = nil;
    PASS(TTIORansDecode(truncated, &err) == nil && err != nil,
         "M83: truncated payload → nil + error");

    // Truncated freq table (cut into the freq table).
    NSData *truncatedFt = [good subdataWithRange:NSMakeRange(0, 50)];
    err = nil;
    PASS(TTIORansDecode(truncatedFt, &err) == nil && err != nil,
         "M83: truncated freq table → nil + error");

    // Decoder must not crash and must produce nil — the suite passes
    // as long as we got here.
    PASS(YES, "M83: malformed-input decoding completes without crash");
}

// ── Test #12: throughput benchmark ─────────────────────────────────

static void testThroughput(void)
{
    const NSUInteger n = 4u << 20;   // 4 MiB
    NSData *data = randomData(n, 0xC0FFEE);

    double t0 = monoSeconds();
    NSData *enc = TTIORansEncode(data, 0);
    double tEnc = monoSeconds() - t0;

    double t1 = monoSeconds();
    NSError *err = nil;
    NSData *dec = TTIORansDecode(enc, &err);
    double tDec = monoSeconds() - t1;

    double mb = (double)n / (1024.0 * 1024.0);
    double encMBs = mb / tEnc;
    double decMBs = mb / tDec;
    fprintf(stderr,
            "  M83 throughput (4 MiB, order-0): "
            "encode %.1f MB/s (%.3fs), decode %.1f MB/s (%.3fs)\n",
            encMBs, tEnc, decMBs, tDec);

    PASS([dec isEqualToData:data], "M83: throughput: round-trip byte-exact");

    // Hard-fail floor at 50% of the soft target (per HANDOFF gotchas).
    PASS(encMBs >= 25.0,
         "M83: encode throughput ≥ 25 MB/s hard floor (got %.1f MB/s, soft target 50)",
         encMBs);
    PASS(decMBs >= 100.0,
         "M83: decode throughput ≥ 100 MB/s hard floor (got %.1f MB/s, soft target 200)",
         decMBs);
}

// ── Public entry point ─────────────────────────────────────────────

void testM83Rans(void);
void testM83Rans(void)
{
    testRoundTripRandomOrder0();
    testRoundTripRandomOrder1();
    testRoundTripBiasedOrder0();
    testRoundTripAllIdentical();
    testRoundTripEmpty();
    testRoundTripSingleByte();
    testCanonicalVectorAOrder0();
    testCanonicalVectorBOrder0();
    testCanonicalVectorCOrder0();
    testCanonicalVectorCOrder1();
    testDecodeMalformed();
    testThroughput();
}
