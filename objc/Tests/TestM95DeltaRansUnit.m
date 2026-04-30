// TestM95DeltaRansUnit.m — M95 DELTA_RANS_ORDER0 ObjC unit tests.
//
// Validates the M95 codec at objc/Source/Codecs/TTIODeltaRans.{h,m}.
// Mirrors python/tests/test_m95_delta_rans.py for cross-language
// verification.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIODeltaRans.h"

#include <stdint.h>
#include <string.h>

// -- Fixture loader ---------------------------------------------------------

static NSString *deltaRansFixtureDir(void)
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
                NSString *probe = [cand stringByAppendingPathComponent:
                    @"delta_rans_a.bin"];
                if ([fm fileExistsAtPath:probe]) {
                    return cand;
                }
            }
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

static NSData *loadDeltaRansFixture(NSString *name)
{
    NSString *dir = deltaRansFixtureDir();
    if (!dir) return nil;
    return [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent:name]];
}

// -- Round-trip tests -------------------------------------------------------

static void testRoundTripInt64SortedAscending(void)
{
    int64_t values[100];
    for (int i = 0; i < 100; i++) values[i] = 1000 + (int64_t)i * 150;
    NSData *raw = [NSData dataWithBytes:values length:sizeof(values)];
    NSError *err = nil;
    NSData *encoded = TTIODeltaRansEncode(raw, 8, &err);
    PASS(encoded != nil && err == nil,
         "M95: encode int64 sorted ascending succeeds");
    if (!encoded) return;

    const uint8_t *hdr = (const uint8_t *)encoded.bytes;
    PASS(memcmp(hdr, "DRA0", 4) == 0, "M95: magic is DRA0");
    PASS(hdr[4] == 1, "M95: version is 1");
    PASS(hdr[5] == 8, "M95: element_size is 8");

    NSData *decoded = TTIODeltaRansDecode(encoded, &err);
    PASS(decoded != nil && [decoded isEqualToData:raw],
         "M95: round-trip int64 sorted ascending");
}

static void testRoundTripInt32Mixed(void)
{
    int32_t values[] = {-100, 50, 0, 300, -300, 12345, -12345, 0};
    NSData *raw = [NSData dataWithBytes:values length:sizeof(values)];
    NSError *err = nil;
    NSData *encoded = TTIODeltaRansEncode(raw, 4, &err);
    PASS(encoded != nil && err == nil,
         "M95: encode int32 mixed succeeds");
    if (!encoded) return;
    NSData *decoded = TTIODeltaRansDecode(encoded, &err);
    PASS(decoded != nil && [decoded isEqualToData:raw],
         "M95: round-trip int32 mixed");
}

static void testRoundTripInt8(void)
{
    int8_t values[] = {-128, -1, 0, 1, 127, 42, -42};
    NSData *raw = [NSData dataWithBytes:values length:sizeof(values)];
    NSError *err = nil;
    NSData *encoded = TTIODeltaRansEncode(raw, 1, &err);
    PASS(encoded != nil && err == nil,
         "M95: encode int8 succeeds");
    if (!encoded) return;
    NSData *decoded = TTIODeltaRansDecode(encoded, &err);
    PASS(decoded != nil && [decoded isEqualToData:raw],
         "M95: round-trip int8");
}

// -- Empty and single element -----------------------------------------------

static void testEmptyInput(void)
{
    NSData *raw = [NSData data];
    NSError *err = nil;
    NSData *encoded = TTIODeltaRansEncode(raw, 8, &err);
    PASS(encoded != nil, "M95: encode empty succeeds");
    if (!encoded) return;
    NSData *decoded = TTIODeltaRansDecode(encoded, &err);
    PASS(decoded != nil && decoded.length == 0,
         "M95: round-trip empty");
}

static void testSingleElement(void)
{
    int64_t val = 42;
    NSData *raw = [NSData dataWithBytes:&val length:sizeof(val)];
    NSError *err = nil;
    NSData *encoded = TTIODeltaRansEncode(raw, 8, &err);
    PASS(encoded != nil, "M95: encode single int64 succeeds");
    if (!encoded) return;
    NSData *decoded = TTIODeltaRansDecode(encoded, &err);
    PASS(decoded != nil && [decoded isEqualToData:raw],
         "M95: round-trip single int64");
}

// -- Error rejection --------------------------------------------------------

static void testBadMagic(void)
{
    uint8_t bad[64];
    memset(bad, 0, sizeof(bad));
    bad[0] = 'X'; bad[1] = 'X'; bad[2] = 'X'; bad[3] = 'X';
    bad[4] = 1; bad[5] = 8;
    NSData *blob = [NSData dataWithBytes:bad length:64];
    NSError *err = nil;
    NSData *result = TTIODeltaRansDecode(blob, &err);
    PASS(result == nil && err != nil,
         "M95: bad magic decode returns nil + error");
}

static void testBadVersion(void)
{
    uint8_t bad[64];
    memset(bad, 0, sizeof(bad));
    memcpy(bad, "DRA0", 4);
    bad[4] = 99; bad[5] = 8;
    NSData *blob = [NSData dataWithBytes:bad length:64];
    NSError *err = nil;
    NSData *result = TTIODeltaRansDecode(blob, &err);
    PASS(result == nil && err != nil,
         "M95: bad version decode returns nil + error");
}

static void testBadElementSize(void)
{
    NSError *err = nil;
    int32_t val = 42;
    NSData *raw = [NSData dataWithBytes:&val length:4];
    NSData *result = TTIODeltaRansEncode(raw, 3, &err);
    PASS(result == nil && err != nil,
         "M95: invalid element_size=3 encode returns nil + error");
}

static void testDataNotMultiple(void)
{
    uint8_t bytes[5] = {1, 2, 3, 4, 5};
    NSData *raw = [NSData dataWithBytes:bytes length:5];
    NSError *err = nil;
    NSData *result = TTIODeltaRansEncode(raw, 4, &err);
    PASS(result == nil && err != nil,
         "M95: data length not multiple of element_size returns nil + error");
}

// -- Fixture decode parity --------------------------------------------------

static void testFixtureA(void)
{
    NSData *enc = loadDeltaRansFixture(@"delta_rans_a.bin");
    PASS(enc != nil, "M95: fixture A loads");
    if (!enc) return;
    NSError *err = nil;
    NSData *dec = TTIODeltaRansDecode(enc, &err);
    PASS(dec != nil && dec.length == 1000 * 8,
         "M95 fixture A: decode gives 1000 int64 (err=%@)",
         err.localizedDescription);
    if (!dec || dec.length != 1000 * 8) return;

    /* Verify sorted ascending. */
    const int64_t *vals = (const int64_t *)dec.bytes;
    BOOL sorted = YES;
    for (int i = 0; i < 999; i++) {
        if (vals[i] >= vals[i + 1]) { sorted = NO; break; }
    }
    PASS(sorted, "M95 fixture A: values sorted ascending");

    /* Re-encode and verify byte-exact match. */
    NSData *reenc = TTIODeltaRansEncode(dec, 8, &err);
    PASS(reenc != nil && [reenc isEqualToData:enc],
         "M95 fixture A: re-encode is byte-exact vs Python (got %lu, want %lu)",
         (unsigned long)reenc.length, (unsigned long)enc.length);
}

static void testFixtureB(void)
{
    NSData *enc = loadDeltaRansFixture(@"delta_rans_b.bin");
    PASS(enc != nil, "M95: fixture B loads");
    if (!enc) return;
    NSError *err = nil;
    NSData *dec = TTIODeltaRansDecode(enc, &err);
    PASS(dec != nil && dec.length == 100 * 4,
         "M95 fixture B: decode gives 100 int32 (err=%@)",
         err.localizedDescription);
    if (!dec || dec.length != 100 * 4) return;

    /* Verify values are from the expected set {0, 16, 83, 99, 163}. */
    const int32_t *vals = (const int32_t *)dec.bytes;
    BOOL validSet = YES;
    for (int i = 0; i < 100; i++) {
        int32_t v = vals[i];
        if (v != 0 && v != 16 && v != 83 && v != 99 && v != 163) {
            validSet = NO; break;
        }
    }
    PASS(validSet, "M95 fixture B: values in expected set");

    /* Re-encode byte-exact. */
    NSData *reenc = TTIODeltaRansEncode(dec, 4, &err);
    PASS(reenc != nil && [reenc isEqualToData:enc],
         "M95 fixture B: re-encode is byte-exact vs Python (got %lu, want %lu)",
         (unsigned long)reenc.length, (unsigned long)enc.length);
}

static void testFixtureC(void)
{
    NSData *enc = loadDeltaRansFixture(@"delta_rans_c.bin");
    PASS(enc != nil, "M95: fixture C loads");
    if (!enc) return;
    NSError *err = nil;
    NSData *dec = TTIODeltaRansDecode(enc, &err);
    PASS(dec != nil && dec.length == 0,
         "M95 fixture C: decode gives empty (err=%@)",
         err.localizedDescription);
}

static void testFixtureD(void)
{
    NSData *enc = loadDeltaRansFixture(@"delta_rans_d.bin");
    PASS(enc != nil, "M95: fixture D loads");
    if (!enc) return;
    NSError *err = nil;
    NSData *dec = TTIODeltaRansDecode(enc, &err);
    PASS(dec != nil && dec.length == 8,
         "M95 fixture D: decode gives 1 int64 (err=%@)",
         err.localizedDescription);
    if (!dec || dec.length != 8) return;

    const int64_t *vals = (const int64_t *)dec.bytes;
    PASS(vals[0] == 1234567890LL,
         "M95 fixture D: value is 1234567890 (got %lld)",
         (long long)vals[0]);

    /* Re-encode byte-exact. */
    NSData *reenc = TTIODeltaRansEncode(dec, 8, &err);
    PASS(reenc != nil && [reenc isEqualToData:enc],
         "M95 fixture D: re-encode is byte-exact vs Python");
}

// -- Public entry point -----------------------------------------------------

void testM95DeltaRansUnit(void);
void testM95DeltaRansUnit(void)
{
    testRoundTripInt64SortedAscending();
    testRoundTripInt32Mixed();
    testRoundTripInt8();
    testEmptyInput();
    testSingleElement();
    testBadMagic();
    testBadVersion();
    testBadElementSize();
    testDataNotMultiple();
    testFixtureA();
    testFixtureB();
    testFixtureC();
    testFixtureD();
}
