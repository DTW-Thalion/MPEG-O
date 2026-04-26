// TestM84BasePack.m — v0.13 M84.
//
// Objective-C normative tests for the clean-room BASE_PACK genomic
// codec + sidecar mask. Mirrors python/tests/test_m84_base_pack.py
// and locks the cross-language wire format via byte-exact fixture
// comparison.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOBasePack.h"

#include <openssl/sha.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// ── Fixture loader (walk upward from CWD looking for objc/Tests/Fixtures)
//
// Same shape as TestM83Rans.m's loader; probes for base_pack_a.bin
// instead of rans_a_o0.bin.

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
            NSString *probe = [candidate stringByAppendingPathComponent:@"base_pack_a.bin"];
            if ([fm fileExistsAtPath:probe]) return candidate;
        }
        NSString *candidate2 = [[[here
                stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"];
        if ([fm fileExistsAtPath:candidate2 isDirectory:&isDir] && isDir) {
            NSString *probe = [candidate2 stringByAppendingPathComponent:@"base_pack_a.bin"];
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

// ── Canonical vector builders (HANDOFF.md §7) ──────────────────────

static NSData *vectorA(void)
{
    // SHA-256("ttio-base-pack-vector-a") repeated 8 times = 256 byte
    // seed; each byte b -> "ACGT"[b & 3].
    static const char salt[] = "ttio-base-pack-vector-a";
    uint8_t digest[32];
    SHA256((const uint8_t *)salt, sizeof(salt) - 1, digest);
    NSMutableData *out = [NSMutableData dataWithLength:256];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    static const char acgt[4] = {'A', 'C', 'G', 'T'};
    for (int i = 0; i < 256; i++) {
        p[i] = (uint8_t)acgt[digest[i & 31] & 0x3];
    }
    return out;
}

static NSData *vectorB(void)
{
    // 1024 bytes. Position multiples of 100 -> 'N'; others derived from
    // SHA-256("ttio-base-pack-vector-b") with the
    //   bit_pair = (seed[i % 32] >> ((i // 32) % 4 * 2)) & 0b11
    // rule used by the Python reference.
    static const char salt[] = "ttio-base-pack-vector-b";
    uint8_t digest[32];
    SHA256((const uint8_t *)salt, sizeof(salt) - 1, digest);
    static const char acgt[4] = {'A', 'C', 'G', 'T'};
    NSMutableData *out = [NSMutableData dataWithLength:1024];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    for (int i = 0; i < 1024; i++) {
        if ((i % 100) == 0) {
            p[i] = (uint8_t)'N';
        } else {
            unsigned shift = ((unsigned)(i / 32) % 4u) * 2u;
            unsigned bit_pair = ((unsigned)digest[i & 31] >> shift) & 0x3u;
            p[i] = (uint8_t)acgt[bit_pair];
        }
    }
    return out;
}

static NSData *vectorC(void)
{
    // Hand-constructed 64-byte IUPAC + soft-mask + gap stress.
    // Layout per HANDOFF.md §7:
    //   "ACGT"           0-3   plain ACGT
    //   "acgt"           4-7   soft-mask
    //   "NNNN"           8-11  all-N
    //   "RYSW"           12-15 IUPAC ambiguity
    //   "KMBD"           16-19 more IUPAC
    //   "HVN-"           20-23 IUPAC + N + gap
    //   "....AC..GT.."   24-35 gaps + ACGT
    //   "ACGT" "ACGT"    36-43 plain ACGT
    //   "ACGT" "ACGT"    44-51 plain ACGT
    //   "ACGT" "ACGT"    52-59 plain ACGT
    //   "ACGT"           60-63 plain ACGT (7 reps total = 28 bytes)
    static const char data[64] =
        "ACGT" "acgt" "NNNN" "RYSW" "KMBD" "HVN-"
        "....AC..GT.."
        "ACGT" "ACGT" "ACGT" "ACGT" "ACGT" "ACGT" "ACGT";
    return [NSData dataWithBytes:data length:64];
}

static NSData *vectorD(void)
{
    return [NSData data];
}

// ── Helpers ────────────────────────────────────────────────────────

static double monoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

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

static uint32_t headerField(NSData *enc, NSUInteger off)
{
    const uint8_t *p = (const uint8_t *)enc.bytes;
    return ((uint32_t)p[off] << 24) | ((uint32_t)p[off+1] << 16) |
           ((uint32_t)p[off+2] << 8) | (uint32_t)p[off+3];
}

// ── Test #1: round-trip pure ACGT 1 MiB ────────────────────────────

static void testRoundTripPureACGT(void)
{
    const NSUInteger n = 1u << 20;   // 1 MiB
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)data.mutableBytes;
    static const char tile[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < n; i++) p[i] = (uint8_t)tile[i & 3];

    NSData *enc = TTIOBasePackEncode(data);
    PASS(enc != nil, "M84: pure-ACGT 1 MiB encode succeeds");
    PASS(enc.length == 13 + 262144,
         "M84: pure-ACGT 1 MiB total wire size = 262157 (got %lu)",
         (unsigned long)enc.length);
    PASS(headerField(enc, 9) == 0,
         "M84: pure-ACGT 1 MiB mask_count = 0 (got %u)",
         (unsigned)headerField(enc, 9));

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS(dec != nil && err == nil, "M84: pure-ACGT 1 MiB decode succeeds");
    PASS([dec isEqualToData:data],
         "M84: pure-ACGT 1 MiB round-trips byte-exact");
}

// ── Test #2: round-trip realistic 1 MiB with N every 100 bases ─────

static void testRoundTripRealistic(void)
{
    const NSUInteger n = 1u << 20;
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)data.mutableBytes;
    static const char tile[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < n; i++) p[i] = (uint8_t)tile[i & 3];
    for (NSUInteger i = 0; i < n; i += 100) p[i] = (uint8_t)'N';

    NSData *enc = TTIOBasePackEncode(data);
    PASS(enc != nil, "M84: realistic 1 MiB encode succeeds");
    // ceil(1048576 / 100) = 10486
    PASS(headerField(enc, 9) == 10486,
         "M84: realistic 1 MiB mask_count = 10486 (got %u)",
         (unsigned)headerField(enc, 9));

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS(dec != nil && err == nil, "M84: realistic 1 MiB decode succeeds");
    PASS([dec isEqualToData:data],
         "M84: realistic 1 MiB round-trips byte-exact");
}

// ── Test #3: round-trip all-N 1 MiB ────────────────────────────────

static void testRoundTripAllN(void)
{
    const NSUInteger n = 1u << 20;
    NSMutableData *data = [NSMutableData dataWithLength:n];
    memset(data.mutableBytes, 'N', n);

    NSData *enc = TTIOBasePackEncode(data);
    PASS(enc != nil, "M84: all-N 1 MiB encode succeeds");
    PASS(headerField(enc, 9) == n,
         "M84: all-N 1 MiB mask_count = orig (got %u)",
         (unsigned)headerField(enc, 9));
    PASS(enc.length == 13 + 262144 + 5 * (1u << 20),
         "M84: all-N 1 MiB total wire size = 5505037 (got %lu)",
         (unsigned long)enc.length);

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS(dec != nil && err == nil, "M84: all-N 1 MiB decode succeeds");
    PASS([dec isEqualToData:data],
         "M84: all-N 1 MiB round-trips byte-exact");
}

// ── Test #4: round-trip empty ──────────────────────────────────────

static void testRoundTripEmpty(void)
{
    NSData *empty = [NSData data];
    NSData *enc = TTIOBasePackEncode(empty);
    PASS(enc != nil, "M84: empty encode succeeds");
    PASS(enc.length == 13,
         "M84: empty wire size = 13 (got %lu)", (unsigned long)enc.length);

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS(dec != nil && err == nil && dec.length == 0,
         "M84: empty round-trips to empty");
}

// ── Test #5: round-trip single ACGT + 2-base + 3-base padding ──────

static void testRoundTripSingleBases(void)
{
    static const struct {
        const char *seq;
        size_t len;
        uint8_t expected_byte;
        const char *label;
    } cases[] = {
        { "A",   1, 0x00, "A"   },
        { "C",   1, 0x40, "C"   },
        { "G",   1, 0x80, "G"   },
        { "T",   1, 0xC0, "T"   },
        { "AC",  2, 0x10, "AC"  },
        { "ACG", 3, 0x18, "ACG" },
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        NSData *data = [NSData dataWithBytes:cases[i].seq length:cases[i].len];
        NSData *enc = TTIOBasePackEncode(data);
        PASS(enc.length == 13 + 1,
             "M84: single-input '%s' wire size = 14 (got %lu)",
             cases[i].label, (unsigned long)enc.length);
        const uint8_t bodyByte = ((const uint8_t *)enc.bytes)[13];
        PASS(bodyByte == cases[i].expected_byte,
             "M84: single-input '%s' body byte = 0x%02x (got 0x%02x)",
             cases[i].label, (unsigned)cases[i].expected_byte, (unsigned)bodyByte);

        NSError *err = nil;
        NSData *dec = TTIOBasePackDecode(enc, &err);
        PASS([dec isEqualToData:data],
             "M84: single-input '%s' round-trips byte-exact", cases[i].label);
    }
}

// ── Test #6: round-trip single N ───────────────────────────────────

static void testRoundTripSingleN(void)
{
    NSData *data = [NSData dataWithBytes:"N" length:1];
    NSData *enc = TTIOBasePackEncode(data);
    PASS(enc.length == 19,
         "M84: single-N wire size = 19 (got %lu)", (unsigned long)enc.length);
    PASS(headerField(enc, 9) == 1,
         "M84: single-N mask_count = 1 (got %u)",
         (unsigned)headerField(enc, 9));

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS([dec isEqualToData:data],
         "M84: single-N round-trips byte-exact");
}

// ── Test #7: IUPAC stress ──────────────────────────────────────────

static void testIUPACStress(void)
{
    NSData *data = [NSData dataWithBytes:"ACGTacgtNRYSWKMBDHV-." length:21];
    NSData *enc = TTIOBasePackEncode(data);
    PASS(enc != nil, "M84: IUPAC stress encode succeeds");
    PASS(headerField(enc, 9) == 17,
         "M84: IUPAC stress mask_count = 17 (got %u)",
         (unsigned)headerField(enc, 9));

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS([dec isEqualToData:data],
         "M84: IUPAC stress round-trips byte-exact");
}

// ── Tests #8–#11: canonical-vector byte-exact conformance ──────────

static void testCanonicalVectorA(void)
{
    NSData *fixture = loadFixture(@"base_pack_a.bin");
    PASS(fixture != nil, "M84: base_pack_a.bin fixture loads");
    NSData *data = vectorA();
    NSData *enc = TTIOBasePackEncode(data);
    compareDataDumpHexOnFail(enc, fixture, "vector A");
    PASS([enc isEqualToData:fixture],
         "M84: vector A byte-exact match against Python fixture");
    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(fixture, &err);
    PASS([dec isEqualToData:data],
         "M84: vector A fixture decodes back to vector A");
}

static void testCanonicalVectorB(void)
{
    NSData *fixture = loadFixture(@"base_pack_b.bin");
    PASS(fixture != nil, "M84: base_pack_b.bin fixture loads");
    NSData *data = vectorB();
    NSData *enc = TTIOBasePackEncode(data);
    compareDataDumpHexOnFail(enc, fixture, "vector B");
    PASS([enc isEqualToData:fixture],
         "M84: vector B byte-exact match against Python fixture");
    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(fixture, &err);
    PASS([dec isEqualToData:data],
         "M84: vector B fixture decodes back to vector B");
}

static void testCanonicalVectorC(void)
{
    NSData *fixture = loadFixture(@"base_pack_c.bin");
    PASS(fixture != nil, "M84: base_pack_c.bin fixture loads");
    NSData *data = vectorC();
    PASS(data.length == 64,
         "M84: vector C input length = 64 (got %lu)",
         (unsigned long)data.length);
    NSData *enc = TTIOBasePackEncode(data);
    compareDataDumpHexOnFail(enc, fixture, "vector C");
    PASS([enc isEqualToData:fixture],
         "M84: vector C byte-exact match against Python fixture");
    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(fixture, &err);
    PASS([dec isEqualToData:data],
         "M84: vector C fixture decodes back to vector C");
}

static void testCanonicalVectorD(void)
{
    NSData *fixture = loadFixture(@"base_pack_d.bin");
    PASS(fixture != nil, "M84: base_pack_d.bin fixture loads");
    PASS(fixture.length == 13,
         "M84: vector D fixture length = 13 (got %lu)",
         (unsigned long)fixture.length);
    NSData *enc = TTIOBasePackEncode(vectorD());
    PASS([enc isEqualToData:fixture],
         "M84: vector D byte-exact match against Python fixture");
}

// ── Test #12: malformed input handling ─────────────────────────────

static void testDecodeMalformed(void)
{
    NSError *err = nil;

    // Build a known-good "ACGTN" stream (orig=5, packed=2, mask=1,
    // total = 13 + 2 + 5 = 20).
    NSData *good = TTIOBasePackEncode([NSData dataWithBytes:"ACGTN" length:5]);

    // (a) Truncated: header says mask_count > 0 but body too short.
    // Drop the trailing mask entry (5 bytes) without updating the header.
    NSData *truncated = [good subdataWithRange:NSMakeRange(0, good.length - 1)];
    err = nil;
    PASS(TTIOBasePackDecode(truncated, &err) == nil && err != nil,
         "M84: truncated stream -> nil + error");

    // (b) Bad version byte (0x01 instead of 0x00).
    NSMutableData *badVer = [good mutableCopy];
    ((uint8_t *)badVer.mutableBytes)[0] = 0x01;
    err = nil;
    PASS(TTIOBasePackDecode(badVer, &err) == nil && err != nil,
         "M84: bad version byte -> nil + error");

    // (c) packed_length mismatch — overwrite the packed_length field
    // (offset 5..8) with 999.
    NSMutableData *badPL = [good mutableCopy];
    {
        uint8_t *p = (uint8_t *)badPL.mutableBytes;
        p[5] = 0; p[6] = 0; p[7] = 3; p[8] = (uint8_t)0xE7; // 999
    }
    err = nil;
    PASS(TTIOBasePackDecode(badPL, &err) == nil && err != nil,
         "M84: packed_length mismatch -> nil + error");

    // (d) Mask position out of range — set the position field of the
    // single mask entry (at offset 13 + 2 = 15) to a value >= orig_len.
    NSMutableData *badPos = [good mutableCopy];
    {
        uint8_t *p = (uint8_t *)badPos.mutableBytes;
        const NSUInteger maskOff = 13 + 2;
        p[maskOff + 0] = 0; p[maskOff + 1] = 0;
        p[maskOff + 2] = 0; p[maskOff + 3] = 99;   // pos = 99 >= 5
    }
    err = nil;
    PASS(TTIOBasePackDecode(badPos, &err) == nil && err != nil,
         "M84: mask position out of range -> nil + error");

    // (e) Mask positions out of order — encode "NN" (orig=2, packed=1,
    // mask=2 entries at positions 0 and 1) and swap them.
    NSData *twoN = TTIOBasePackEncode([NSData dataWithBytes:"NN" length:2]);
    NSMutableData *badOrder = [twoN mutableCopy];
    {
        uint8_t *p = (uint8_t *)badOrder.mutableBytes;
        const NSUInteger e0 = 13 + 1;       // first mask entry @ pos 14
        const NSUInteger e1 = e0 + 5;       // second mask entry @ pos 19
        uint8_t tmp[5];
        memcpy(tmp,        p + e0, 5);
        memcpy(p + e0,     p + e1, 5);
        memcpy(p + e1,     tmp,    5);
    }
    err = nil;
    PASS(TTIOBasePackDecode(badOrder, &err) == nil && err != nil,
         "M84: mask positions out of order -> nil + error");

    // Decoder must not crash; the suite passing means we got here.
    PASS(YES, "M84: malformed-input decoding completes without crash");
}

// ── Test #13: soft-masking round-trip ──────────────────────────────

static void testSoftMaskingRoundTrip(void)
{
    NSData *data = [NSData dataWithBytes:"ACGTacgtACGT" length:12];
    NSData *enc = TTIOBasePackEncode(data);
    PASS(enc != nil, "M84: soft-masking encode succeeds");
    PASS(headerField(enc, 9) == 4,
         "M84: soft-masking mask_count = 4 (got %u)",
         (unsigned)headerField(enc, 9));

    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    PASS([dec isEqualToData:data],
         "M84: soft-masking round-trips byte-exact (case preserved)");
}

// ── Test #14: throughput ───────────────────────────────────────────

static void testThroughput(void)
{
    const NSUInteger n = 4u << 20;   // 4 MiB pure ACGT
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)data.mutableBytes;
    static const char tile[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < n; i++) p[i] = (uint8_t)tile[i & 3];

    double t0 = monoSeconds();
    NSData *enc = TTIOBasePackEncode(data);
    double tEnc = monoSeconds() - t0;

    double t1 = monoSeconds();
    NSError *err = nil;
    NSData *dec = TTIOBasePackDecode(enc, &err);
    double tDec = monoSeconds() - t1;

    double mb = (double)n / (1024.0 * 1024.0);
    double encMBs = (tEnc > 0.0) ? (mb / tEnc) : 0.0;
    double decMBs = (tDec > 0.0) ? (mb / tDec) : 0.0;
    fprintf(stderr,
            "  M84 throughput (4 MiB pure ACGT): "
            "encode %.1f MB/s (%.3fs), decode %.1f MB/s (%.3fs)\n",
            encMBs, tEnc, decMBs, tDec);

    PASS([dec isEqualToData:data], "M84: throughput round-trip byte-exact");

    // Hard floors per HANDOFF §8.2 acceptance: encode ≥ 100 MB/s,
    // decode ≥ 250 MB/s. Soft targets 200 / 500.
    PASS(encMBs >= 100.0,
         "M84: encode throughput ≥ 100 MB/s hard floor (got %.1f MB/s, soft target 200)",
         encMBs);
    PASS(decMBs >= 250.0,
         "M84: decode throughput ≥ 250 MB/s hard floor (got %.1f MB/s, soft target 500)",
         decMBs);
}

// ── Public entry point ─────────────────────────────────────────────

void testM84BasePack(void);
void testM84BasePack(void)
{
    testRoundTripPureACGT();
    testRoundTripRealistic();
    testRoundTripAllN();
    testRoundTripEmpty();
    testRoundTripSingleBases();
    testRoundTripSingleN();
    testIUPACStress();
    testCanonicalVectorA();
    testCanonicalVectorB();
    testCanonicalVectorC();
    testCanonicalVectorD();
    testDecodeMalformed();
    testSoftMaskingRoundTrip();
    testThroughput();
}
