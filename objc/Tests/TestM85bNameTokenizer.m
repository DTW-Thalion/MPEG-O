// TestM85bNameTokenizer.m — M85 Phase B.
//
// Objective-C normative tests for the clean-room NAME_TOKENIZED
// genomic codec — lean two-token-type columnar codec with
// per-column type detection (columnar vs verbatim), delta-encoded
// numeric columns and inline-dictionary-encoded string columns.
// Mirrors python/tests/test_m85b_name_tokenizer.py and locks the
// cross-language wire format via byte-exact fixture comparison
// against name_tok_{a,b,c,d}.bin.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIONameTokenizer.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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
            NSString *probe = [candidate stringByAppendingPathComponent:@"name_tok_a.bin"];
            if ([fm fileExistsAtPath:probe]) return candidate;
        }
        NSString *candidate2 = [[[here
                stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"];
        if ([fm fileExistsAtPath:candidate2 isDirectory:&isDir] && isDir) {
            NSString *probe = [candidate2 stringByAppendingPathComponent:@"name_tok_a.bin"];
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
        NSUInteger hi = (firstDiff + 16 < min) ? firstDiff + 16 : min;
        fprintf(stderr, "    got: ");
        for (NSUInteger i = lo; i < hi; i++)
            fprintf(stderr, "%02x ", g[i]);
        fprintf(stderr, "\n   want: ");
        for (NSUInteger i = lo; i < hi; i++)
            fprintf(stderr, "%02x ", w[i]);
        fprintf(stderr, "\n");
    } else {
        // Same prefix but lengths differ: dump tails.
        fprintf(stderr, "    common prefix matches; lengths differ.\n");
    }
}

static double monoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// ── Canonical vector builders (HANDOFF M85B §8) ────────────────────

static NSArray<NSString *> *vectorA(void)
{
    return @[
        @"INSTR:RUN:1:101:1000:2000",
        @"INSTR:RUN:1:101:1000:2001",
        @"INSTR:RUN:1:101:1001:2000",
        @"INSTR:RUN:1:101:1001:2001",
        @"INSTR:RUN:1:102:1000:2000",
    ];
}

static NSArray<NSString *> *vectorB(void)
{
    return @[@"A", @"AB", @"AB:C", @"AB:C:D"];
}

static NSArray<NSString *> *vectorC(void)
{
    return @[@"r007:1", @"r008:2", @"r009:3", @"r010:4", @"r011:5", @"r012:6"];
}

static NSArray<NSString *> *vectorD(void)
{
    return @[];
}

// Sum of byte lengths of every name (for compression-ratio asserts).
static NSUInteger sumRawBytes(NSArray<NSString *> *names)
{
    NSUInteger total = 0;
    for (NSString *s in names) {
        total += [s lengthOfBytesUsingEncoding:NSASCIIStringEncoding];
    }
    return total;
}

// Fetch the mode byte (offset 2 in header) from an encoded stream.
static uint8_t modeByte(NSData *enc)
{
    if (enc.length < 7) return 0xFF;
    return ((const uint8_t *)enc.bytes)[2];
}

// ── Test #1: round-trip columnar basic ─────────────────────────────

static void testRoundTripColumnarBasic(void)
{
    NSArray *names = @[@"READ:1:2", @"READ:1:3", @"READ:1:4"];
    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(enc != nil, "M85B: columnar-basic encode succeeds");
    PASS(modeByte(enc) == 0x00,
         "M85B: columnar-basic mode byte == 0x00 (got 0x%02x)",
         (unsigned)modeByte(enc));

    // Header well-formedness: version=0, scheme_id=0, mode=0,
    // n_reads=3 (uint32 BE).
    const uint8_t *p = enc.bytes;
    PASS(p[0] == 0x00, "M85B: columnar-basic version byte = 0x00");
    PASS(p[1] == 0x00, "M85B: columnar-basic scheme_id = 0x00");
    PASS(p[3] == 0 && p[4] == 0 && p[5] == 0 && p[6] == 3,
         "M85B: columnar-basic n_reads (uint32 BE) = 3");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85B: columnar-basic decode succeeds");
    PASS([dec isEqualToArray:names],
         "M85B: columnar-basic round-trips byte-exact");
}

// ── Test #2: 1000 deterministic Illumina-style names ───────────────

static void testRoundTripColumnarIllumina(void)
{
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:1000];
    for (int tile = 0; tile < 10; tile++) {
        for (int x = 0; x < 10; x++) {
            for (int y = 0; y < 10; y++) {
                [names addObject:
                    [NSString stringWithFormat:@"INSTR:RUN:LANE:%d:%d:%d",
                                                tile, x, y]];
            }
        }
    }
    PASS(names.count == 1000, "M85B: Illumina batch has 1000 names");

    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(enc != nil, "M85B: Illumina batch encodes");
    PASS(modeByte(enc) == 0x00,
         "M85B: Illumina batch picks columnar mode (got 0x%02x)",
         (unsigned)modeByte(enc));

    const NSUInteger raw = sumRawBytes(names);
    const double ratio = (double)raw / (double)enc.length;
    fprintf(stderr,
            "  M85B: 1000 Illumina names: raw=%lu, encoded=%lu, ratio=%.2fx\n",
            (unsigned long)raw, (unsigned long)enc.length, ratio);
    PASS(ratio >= 3.0,
         "M85B: Illumina batch compression ratio %.2fx >= 3.0x", ratio);

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85B: Illumina batch decodes");
    PASS([dec isEqualToArray:names],
         "M85B: Illumina batch round-trips byte-exact");
}

// ── Test #3: verbatim (ragged token counts) ────────────────────────

static void testRoundTripVerbatimRagged(void)
{
    NSArray *names = @[@"a:1", @"ab", @"a:b:c"];
    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(enc != nil, "M85B: ragged-verbatim encode succeeds");
    PASS(modeByte(enc) == 0x01,
         "M85B: ragged-verbatim mode byte == 0x01 (got 0x%02x)",
         (unsigned)modeByte(enc));

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85B: ragged-verbatim decode succeeds");
    PASS([dec isEqualToArray:names],
         "M85B: ragged-verbatim round-trips byte-exact");
}

// ── Test #4: verbatim (same count, type mismatch) ──────────────────

static void testRoundTripVerbatimTypeMismatch(void)
{
    NSArray *names = @[@"a:1", @"a:b", @"a:1"];
    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(modeByte(enc) == 0x01,
         "M85B: type-mismatch falls back to verbatim (got 0x%02x)",
         (unsigned)modeByte(enc));

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS([dec isEqualToArray:names],
         "M85B: type-mismatch round-trips byte-exact");
}

// ── Test #5: empty list ────────────────────────────────────────────

static void testRoundTripEmptyList(void)
{
    NSArray *names = @[];
    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(enc.length == 8,
         "M85B: empty list wire size = 8 (got %lu)",
         (unsigned long)enc.length);

    const uint8_t expected[8] = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    PASS(memcmp(enc.bytes, expected, 8) == 0,
         "M85B: empty list bytes = 00 00 00 00 00 00 00 00");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS(dec != nil && err == nil && dec.count == 0,
         "M85B: empty list decodes to empty array");
}

// ── Test #6: single-read batch ─────────────────────────────────────

static void testRoundTripSingleRead(void)
{
    {
        NSArray *names = @[@"only"];
        NSData *enc = TTIONameTokenizerEncode(names);
        PASS(modeByte(enc) == 0x00,
             "M85B: single read 'only' uses columnar mode");

        NSError *err = nil;
        NSArray *dec = TTIONameTokenizerDecode(enc, &err);
        PASS([dec isEqualToArray:names],
             "M85B: single read 'only' round-trips");
    }
    {
        NSArray *names = @[@"only:42"];
        NSData *enc = TTIONameTokenizerEncode(names);
        PASS(modeByte(enc) == 0x00,
             "M85B: single read 'only:42' uses columnar mode");

        NSError *err = nil;
        NSArray *dec = TTIONameTokenizerDecode(enc, &err);
        PASS([dec isEqualToArray:names],
             "M85B: single read 'only:42' round-trips");
    }
}

// ── Test #7: leading-zero absorption ───────────────────────────────

static void testRoundTripLeadingZero(void)
{
    NSArray *names = @[@"r007", @"r008", @"r009"];
    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(modeByte(enc) == 0x00,
         "M85B: leading-zero batch uses columnar mode");

    // Each name tokenises to a single string token "rNNN", so the
    // body should be: n_columns=1, type_table=[0x01], then string
    // column with 3 dict entries.
    const uint8_t *p = enc.bytes;
    PASS(p[7] == 0x01, "M85B: leading-zero n_columns == 1 (got %u)",
         (unsigned)p[7]);
    PASS(p[8] == 0x01, "M85B: leading-zero column type = string (got 0x%02x)",
         (unsigned)p[8]);

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS([dec isEqualToArray:names],
         "M85B: leading-zero batch round-trips byte-exact");
}

// ── Test #8: oversize numeric demoted to string ────────────────────

static void testRoundTripOversizeNumeric(void)
{
    // 20 digits exceeds 2^63 - 1 (which has 19 digits).
    NSArray *names = @[
        @"r99999999999999999999",
        @"r99999999999999999998",
        @"r99999999999999999997",
    ];
    NSData *enc = TTIONameTokenizerEncode(names);
    PASS(enc != nil, "M85B: oversize-numeric batch encodes");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    PASS(dec != nil && err == nil, "M85B: oversize-numeric batch decodes");
    PASS([dec isEqualToArray:names],
         "M85B: oversize-numeric round-trips byte-exact (demoted to string)");

    // Single string token expected ⇒ columnar mode with 1 string column.
    PASS(modeByte(enc) == 0x00,
         "M85B: oversize-numeric uses columnar (mode 0x00)");
    PASS(((const uint8_t *)enc.bytes)[7] == 0x01,
         "M85B: oversize-numeric n_columns == 1");
    PASS(((const uint8_t *)enc.bytes)[8] == 0x01,
         "M85B: oversize-numeric column type = string");
}

// ── Tests #9-#12: canonical vectors A/B/C/D byte-exact ─────────────

static void testCanonicalVectorA(void)
{
    NSData *fixture = loadFixture(@"name_tok_a.bin");
    PASS(fixture != nil, "M85B: name_tok_a.bin fixture loads");
    PASS(fixture.length == 75,
         "M85B: vector A fixture length = 75 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIONameTokenizerEncode(vectorA());
    compareDataDumpHexOnFail(enc, fixture, "vector A");
    PASS([enc isEqualToData:fixture],
         "M85B: vector A byte-exact match against Python fixture");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(fixture, &err);
    PASS([dec isEqualToArray:vectorA()],
         "M85B: vector A fixture decodes back to vector A");

    const NSUInteger raw = sumRawBytes(vectorA());
    const double ratio = (double)raw / (double)enc.length;
    fprintf(stderr,
            "  M85B: vector A raw=%lu encoded=%lu ratio=%.2fx\n",
            (unsigned long)raw, (unsigned long)enc.length, ratio);
}

static void testCanonicalVectorB(void)
{
    NSData *fixture = loadFixture(@"name_tok_b.bin");
    PASS(fixture != nil, "M85B: name_tok_b.bin fixture loads");
    PASS(fixture.length == 30,
         "M85B: vector B fixture length = 30 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIONameTokenizerEncode(vectorB());
    compareDataDumpHexOnFail(enc, fixture, "vector B");
    PASS([enc isEqualToData:fixture],
         "M85B: vector B byte-exact match against Python fixture");
    PASS(modeByte(enc) == 0x00,
         "M85B: vector B mode = columnar 0x00");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(fixture, &err);
    PASS([dec isEqualToArray:vectorB()],
         "M85B: vector B fixture decodes back to vector B");
}

static void testCanonicalVectorC(void)
{
    NSData *fixture = loadFixture(@"name_tok_c.bin");
    PASS(fixture != nil, "M85B: name_tok_c.bin fixture loads");
    PASS(fixture.length == 58,
         "M85B: vector C fixture length = 58 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIONameTokenizerEncode(vectorC());
    compareDataDumpHexOnFail(enc, fixture, "vector C");
    PASS([enc isEqualToData:fixture],
         "M85B: vector C byte-exact match against Python fixture");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(fixture, &err);
    PASS([dec isEqualToArray:vectorC()],
         "M85B: vector C fixture decodes back to vector C");
}

static void testCanonicalVectorD(void)
{
    NSData *fixture = loadFixture(@"name_tok_d.bin");
    PASS(fixture != nil, "M85B: name_tok_d.bin fixture loads");
    PASS(fixture.length == 8,
         "M85B: vector D fixture length = 8 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIONameTokenizerEncode(vectorD());
    PASS([enc isEqualToData:fixture],
         "M85B: vector D byte-exact match against Python fixture");

    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(fixture, &err);
    PASS(dec != nil && err == nil && dec.count == 0,
         "M85B: vector D fixture decodes to empty array");
}

// ── Test #13: malformed input handling ─────────────────────────────

static void testDecodeMalformed(void)
{
    NSError *err = nil;

    // (a) Stream shorter than 7-byte header.
    {
        const uint8_t buf[3] = { 0x00, 0x00, 0x00 };
        NSData *bad = [NSData dataWithBytes:buf length:3];
        err = nil;
        PASS(TTIONameTokenizerDecode(bad, &err) == nil && err != nil,
             "M85B: short stream (3 bytes) -> nil + error");
    }

    // (b) Bad version byte (0x01).
    {
        const uint8_t buf[8] = {
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };
        NSData *bad = [NSData dataWithBytes:buf length:8];
        err = nil;
        PASS(TTIONameTokenizerDecode(bad, &err) == nil && err != nil,
             "M85B: bad version byte 0x01 -> nil + error");
    }

    // (c) Bad scheme_id (0xFF).
    {
        const uint8_t buf[8] = {
            0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };
        NSData *bad = [NSData dataWithBytes:buf length:8];
        err = nil;
        PASS(TTIONameTokenizerDecode(bad, &err) == nil && err != nil,
             "M85B: bad scheme_id 0xFF -> nil + error");
    }

    // (d) Bad mode byte (0xFF) with n_reads = 0 (so columnar/verbatim
    // both would be valid for 0 reads with no body); the bad-mode
    // check fires before the body check.
    {
        const uint8_t buf[7] = {
            0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00,
        };
        NSData *bad = [NSData dataWithBytes:buf length:7];
        err = nil;
        PASS(TTIONameTokenizerDecode(bad, &err) == nil && err != nil,
             "M85B: bad mode byte 0xFF -> nil + error");
    }

    // (e) Truncated body (varint with continuation bit, no follow-up).
    // mode = verbatim, n_reads = 1, body = [0x80] (continuation bit
    // set, no next byte → varint runs off end).
    {
        const uint8_t buf[8] = {
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x80,
        };
        NSData *bad = [NSData dataWithBytes:buf length:8];
        err = nil;
        PASS(TTIONameTokenizerDecode(bad, &err) == nil && err != nil,
             "M85B: truncated varint -> nil + error");
    }

    // (f) Trailing bytes — well-formed columnar empty stream + 1
    // extra trailing byte should be rejected.
    {
        const uint8_t buf[9] = {
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };
        NSData *bad = [NSData dataWithBytes:buf length:9];
        err = nil;
        PASS(TTIONameTokenizerDecode(bad, &err) == nil && err != nil,
             "M85B: trailing bytes -> nil + error");
    }

    PASS(YES, "M85B: malformed-input decoding completes without crash");
}

// ── Test #14: throughput on 100k Illumina-style names ──────────────

static void testThroughput(void)
{
    const int N = 100000;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:N];
    for (int i = 0; i < N; i++) {
        // Same shape as Vector A → columnar mode hits.
        const int lane = (i / 1000) % 10;
        const int tile = (i / 100) % 100;
        const int x = (i / 10) % 100;
        const int y = i % 100;
        [names addObject:
            [NSString stringWithFormat:@"INSTR:RUN:%d:%d:%d:%d",
                                        lane, tile, x, y]];
    }

    const NSUInteger raw = sumRawBytes(names);
    const double mb = (double)raw / (1024.0 * 1024.0);

    double t0 = monoSeconds();
    NSData *enc = TTIONameTokenizerEncode(names);
    double tEnc = monoSeconds() - t0;

    double t1 = monoSeconds();
    NSError *err = nil;
    NSArray *dec = TTIONameTokenizerDecode(enc, &err);
    double tDec = monoSeconds() - t1;

    const double encMBs = (tEnc > 0.0) ? (mb / tEnc) : 0.0;
    const double decMBs = (tDec > 0.0) ? (mb / tDec) : 0.0;
    const double ratio  = (double)raw / (double)enc.length;

    fprintf(stderr,
            "  M85B throughput (100k Illumina names, %.1f MB raw): "
            "encode %.1f MB/s (%.3fs), decode %.1f MB/s (%.3fs), "
            "ratio %.2fx\n",
            mb, encMBs, tEnc, decMBs, tDec, ratio);

    PASS(dec != nil && err == nil && dec.count == (NSUInteger)N,
         "M85B: throughput round-trip yields N=%d names", N);
    PASS([dec isEqualToArray:names],
         "M85B: throughput round-trip byte-exact");

    // Hard floors per HANDOFF M85B §7.2: encode >= 25 MB/s,
    // decode >= 50 MB/s. Soft targets 50 / 100.
    PASS(encMBs >= 25.0,
         "M85B: encode throughput >= 25 MB/s hard floor (got %.1f MB/s, soft target 50)",
         encMBs);
    PASS(decMBs >= 50.0,
         "M85B: decode throughput >= 50 MB/s hard floor (got %.1f MB/s, soft target 100)",
         decMBs);
}

// ── Public entry point ─────────────────────────────────────────────

void testM85bNameTokenizer(void);
void testM85bNameTokenizer(void)
{
    testRoundTripColumnarBasic();
    testRoundTripColumnarIllumina();
    testRoundTripVerbatimRagged();
    testRoundTripVerbatimTypeMismatch();
    testRoundTripEmptyList();
    testRoundTripSingleRead();
    testRoundTripLeadingZero();
    testRoundTripOversizeNumeric();
    testCanonicalVectorA();
    testCanonicalVectorB();
    testCanonicalVectorC();
    testCanonicalVectorD();
    testDecodeMalformed();
    testThroughput();
}
