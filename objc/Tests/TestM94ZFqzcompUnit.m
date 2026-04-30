// TestM94ZFqzcompUnit.m — M94.Z (CRAM-mimic FQZCOMP_NX16) ObjC unit tests.
//
// Validates the M94.Z codec at objc/Source/Codecs/TTIOFqzcompNx16Z.{h,m}.
// Mirrors python/tests/test_m94z_unit.py + test_m94z_canonical_fixtures.py
// for byte-exact cross-language verification.
//
// Phase 4 of M94.Z (per design spec
//   docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md).
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Fixture loader ─────────────────────────────────────────────────

static NSString *m94zFixtureDir(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSArray<NSString *> *cands = @[
            [[here stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"],
            [[[here stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"],
        ];
        for (NSString *cand in cands) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:cand isDirectory:&isDir] && isDir) {
                NSString *probe = [[cand stringByAppendingPathComponent:@"codecs"]
                    stringByAppendingPathComponent:@"m94z_a.bin"];
                if ([fm fileExistsAtPath:probe]) {
                    return [cand stringByAppendingPathComponent:@"codecs"];
                }
            }
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

static NSData *m94zLoadFixture(NSString *name)
{
    NSString *dir = m94zFixtureDir();
    if (!dir) return nil;
    return [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent:name]];
}

static void compareDataDumpHex(NSData *got, NSData *want, const char *label)
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
        for (NSUInteger i = lo; i < hi; i++) fprintf(stderr, "%02x ", g[i]);
        fprintf(stderr, "\n   want: ");
        for (NSUInteger i = lo; i < hi; i++) fprintf(stderr, "%02x ", w[i]);
        fprintf(stderr, "\n");
    }
}

// ── Helpers ────────────────────────────────────────────────────────

static NSData *m94zConstQualities(uint8_t q, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithLength:n];
    memset(d.mutableBytes, q, n);
    return d;
}

static NSArray<NSNumber *> *m94zRepeatNum(NSNumber *v, NSUInteger n)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [a addObject:v];
    return a;
}

// ── Smallest round-trip ────────────────────────────────────────────

static void testM94ZTrivialRoundTrip(void)
{
    NSData *q = m94zConstQualities('I', 12);   // 12× Q40
    NSArray *rl = @[ @12 ];
    NSArray *rc = @[ @0 ];
    NSError *err = nil;
    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                             readLengths:rl
                                            revcompFlags:rc
                                                   error:&err];
    PASS(enc != nil && err == nil,
         "M94.Z: trivial encode succeeds (12× Q40, err=%@)",
         err.localizedDescription);
    if (!enc) return;
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:enc
                                        revcompFlags:rc
                                               error:&err];
    PASS(out != nil, "M94.Z: trivial decode succeeds (err=%@)",
         err.localizedDescription);
    if (!out) return;
    NSData *got = out[@"qualities"];
    PASS([got isEqualToData:q],
         "M94.Z: trivial round-trip recovers qualities byte-exact (got %lu)",
         (unsigned long)got.length);
    NSArray *gotRl = out[@"readLengths"];
    PASS(gotRl.count == 1 && [gotRl[0] unsignedIntegerValue] == 12,
         "M94.Z: trivial round-trip recovers read_lengths");
}

static void testM94ZSmallestFourSymbols(void)
{
    // n=4 — the smallest n with no padding (n_padded == 4 == 1 chunk per lane).
    uint8_t bytes[4] = { 'I', '5', '!', '~' };
    NSData *q = [NSData dataWithBytes:bytes length:4];
    NSArray *rl = @[ @4 ];
    NSArray *rc = @[ @0 ];
    NSError *err = nil;
    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q readLengths:rl
                                            revcompFlags:rc error:&err];
    PASS(enc != nil, "M94.Z: smallest 4-symbol encode (err=%@)",
         err.localizedDescription);
    if (!enc) return;
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rc error:&err];
    PASS(out != nil && [out[@"qualities"] isEqualToData:q],
         "M94.Z: smallest 4-symbol round-trip byte-exact");
}

static void testM94ZRoundTripWithRevcomp(void)
{
    // 4 reads × 8 bytes, alternating revcomp.
    uint8_t bytes[32];
    for (int i = 0; i < 32; i++) bytes[i] = (uint8_t)(33 + (i % 30));
    NSData *q = [NSData dataWithBytes:bytes length:32];
    NSArray *rl = @[ @8, @8, @8, @8 ];
    NSArray *rc = @[ @0, @1, @0, @1 ];
    NSError *err = nil;
    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q readLengths:rl
                                            revcompFlags:rc error:&err];
    PASS(enc != nil, "M94.Z: revcomp-mix encode (err=%@)",
         err.localizedDescription);
    if (!enc) return;
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rc error:&err];
    PASS(out != nil && [out[@"qualities"] isEqualToData:q],
         "M94.Z: revcomp-mix round-trip byte-exact");
}

static void testM94ZPaddingNonMultipleOf4(void)
{
    NSData *q = m94zConstQualities('!', 7);
    NSArray *rl = @[ @7 ];
    NSArray *rc = @[ @0 ];
    NSError *err = nil;
    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q readLengths:rl
                                            revcompFlags:rc error:&err];
    PASS(enc != nil, "M94.Z: 7-byte (non-multiple-of-4) encode (err=%@)",
         err.localizedDescription);
    if (!enc) return;
    // Pad count appears in flags bits 4..5: 7 % 4 = 3 → pad=1.
    const uint8_t *p = (const uint8_t *)enc.bytes;
    PASS(memcmp(p, "M94Z", 4) == 0, "M94.Z: padding case has correct magic");
    PASS(((p[5] >> 4) & 0x3) == 1,
         "M94.Z: pad_count == 1 in flags (got 0x%02x)", p[5]);
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rc error:&err];
    PASS(out != nil && [out[@"qualities"] isEqualToData:q],
         "M94.Z: padding round-trip drops zero pad on decode");
}

// ── Bad magic / version ────────────────────────────────────────────

static void testM94ZBadMagic(void)
{
    uint8_t bad[64] = { 'X', 'X', 'X', 'X', 1, 0 };
    NSData *blob = [NSData dataWithBytes:bad length:64];
    NSError *err = nil;
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:blob error:&err];
    PASS(out == nil && err != nil,
         "M94.Z: bad-magic decode returns nil + error");
}

// ── Canonical fixture round-trip + byte-exact compare ─────────────

static void testM94ZFixtureRoundTrip(NSString *fname,
                                      NSArray<NSNumber *> *revcompFlags)
{
    NSData *fixture = m94zLoadFixture(fname);
    PASS(fixture != nil, "M94.Z: fixture %@ loads", fname);
    if (!fixture) return;

    NSError *err = nil;
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:fixture
                                        revcompFlags:revcompFlags
                                               error:&err];
    PASS(out != nil && err == nil,
         "M94.Z fixture %@: decode succeeds (err=%@)",
         fname, err.localizedDescription ?: @"<none>");
    if (!out) return;

    NSData *qualities = out[@"qualities"];
    NSArray *readLengths = out[@"readLengths"];
    PASS(qualities != nil && readLengths != nil,
         "M94.Z fixture %@: decode populated qualities + readLengths", fname);

    // Re-encode with the same metadata; require byte-exact match.
    NSArray *rcUsed = revcompFlags;
    if (!rcUsed) {
        NSMutableArray *zeros = [NSMutableArray arrayWithCapacity:readLengths.count];
        for (NSUInteger i = 0; i < readLengths.count; i++) [zeros addObject:@0];
        rcUsed = zeros;
    }
    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:qualities
                                             readLengths:readLengths
                                            revcompFlags:rcUsed
                                                   error:&err];
    PASS(enc != nil, "M94.Z fixture %@: re-encode of decoded data succeeds (err=%@)",
         fname, err.localizedDescription);
    if (!enc) return;
    if (![enc isEqualToData:fixture]) {
        compareDataDumpHex(enc, fixture, [fname UTF8String]);
    }
    PASS([enc isEqualToData:fixture],
         "M94.Z fixture %@: encode is byte-exact vs Python (got %lu, want %lu)",
         fname, (unsigned long)enc.length, (unsigned long)fixture.length);
}

static void testM94ZFixtureA(void) {
    NSMutableArray *rc = [NSMutableArray array];
    for (int i = 0; i < 100; i++) [rc addObject:@0];
    testM94ZFixtureRoundTrip(@"m94z_a.bin", rc);
}
static void testM94ZFixtureB(void) {
    NSMutableArray *rc = [NSMutableArray array];
    for (int i = 0; i < 100; i++) [rc addObject:@0];
    testM94ZFixtureRoundTrip(@"m94z_b.bin", rc);
}
static void testM94ZFixtureC(void) {
    NSMutableArray *rc = [NSMutableArray array];
    for (int i = 0; i < 50; i++) [rc addObject:@0];
    testM94ZFixtureRoundTrip(@"m94z_c.bin", rc);
}
static void testM94ZFixtureD(void) {
    testM94ZFixtureRoundTrip(@"m94z_d.bin", @[ @0, @1, @0, @1 ]);
}

// Fixture F uses random.Random(0xF00D) past the qualities stream to
// produce a 100-element 0/1 list with ~80% ones. The exact sequence is
// reproduced from Python — see python/tests/test_m94z_canonical_fixtures.py.
static void testM94ZFixtureF(void) {
    static const uint8_t kFixtureFFlags[100] = {
        1,1,1,1,1,1,1,1,0,1, 0,1,1,1,1,1,1,1,1,0,
        0,1,1,1,1,1,1,1,0,1, 1,0,1,1,1,1,1,1,1,1,
        1,0,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,0,1,
        1,0,1,1,1,1,1,1,1,1, 1,1,1,1,1,0,1,1,1,1,
        1,1,1,1,1,1,1,1,1,1, 1,0,1,1,1,1,0,1,1,1,
    };
    NSMutableArray *rc = [NSMutableArray arrayWithCapacity:100];
    for (int i = 0; i < 100; i++) [rc addObject:@(kFixtureFFlags[i])];
    testM94ZFixtureRoundTrip(@"m94z_f.bin", rc);
}

static void testM94ZFixtureG(void) {
    testM94ZFixtureRoundTrip(@"m94z_g.bin", @[ @0 ]);
}
static void testM94ZFixtureH(void) {
    testM94ZFixtureRoundTrip(@"m94z_h.bin", @[ @0 ]);
}

// ── Public entry point ─────────────────────────────────────────────

void testM94ZFqzcompUnit(void);
void testM94ZFqzcompUnit(void)
{
    testM94ZTrivialRoundTrip();
    testM94ZSmallestFourSymbols();
    testM94ZRoundTripWithRevcomp();
    testM94ZPaddingNonMultipleOf4();
    testM94ZBadMagic();
    testM94ZFixtureA();
    testM94ZFixtureB();
    testM94ZFixtureC();
    testM94ZFixtureD();
    testM94ZFixtureF();
    testM94ZFixtureG();
    testM94ZFixtureH();
}
