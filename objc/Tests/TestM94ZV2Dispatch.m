// TestM94ZV2Dispatch.m — Task 23: M94.Z V2 native-dispatch round-trip.
//
// Mirrors:
//   python/tests/test_m94z_v2_dispatch.py (commit 7efa658)
//   java/src/test/java/.../FqzcompNx16ZV2DispatchTest.java (commit eea54e4)
//
// Verifies:
//   * V1 encode is the default (version byte = 1).
//   * V1 round-trips via the unchanged pure-ObjC path.
//   * When the native library is linked in, options:@{@"preferNative":@YES}
//     produces a V2 stream (version byte = 2) whose body is from
//     ttio_rans_encode_block.
//   * V2 round-trips via the pure-ObjC V2 decoder (option E).
//   * V1 and V2 decode to the same qualities for the same input.
//
// When +backendName is "pure-objc" (libttio_rans not built), the V2
// encode tests are skipped — only the V1 default-path tests run.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"

static NSData *makeQualities(NSUInteger nReads, NSUInteger readLen)
{
    NSMutableData *d = [NSMutableData dataWithLength:nReads * readLen];
    uint8_t *buf = (uint8_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        // Phred+33, range [33+20, 33+40] — typical Illumina spread.
        buf[i] = (uint8_t)(33 + 20 + ((i * 31) % 21));
    }
    return d;
}

static NSArray<NSNumber *> *makeUniformLengths(NSUInteger nReads, NSUInteger readLen)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) [a addObject:@(readLen)];
    return a;
}

static NSArray<NSNumber *> *makeRevcompFlags(NSUInteger nReads, BOOL alternating)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        [a addObject:@(alternating ? (i & 1) : 0)];
    }
    return a;
}

static void testV1DefaultEncode(void)
{
    NSData *q = makeQualities(50, 80);
    NSArray *rls = makeUniformLengths(50, 80);
    NSArray *rcs = makeRevcompFlags(50, NO);
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                                    error:&err];
    PASS(enc != nil, "V1 encode (default path) succeeds");
    if (!enc) return;
    PASS(enc.length > 0, "V1 encode non-empty");
    const uint8_t *bytes = (const uint8_t *)enc.bytes;
    PASS(bytes[0] == 'M' && bytes[1] == '9' && bytes[2] == '4' && bytes[3] == 'Z',
         "V1 magic bytes are M94Z");
    PASS(bytes[4] == 1, "V1 version byte == 1 (default)");

    err = nil;
    NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rcs error:&err];
    PASS(dec != nil, "V1 decode succeeds");
    if (!dec) return;
    PASS([dec[@"qualities"] isEqualToData:q], "V1 round-trip matches input qualities");
}

static void testV1ExplicitNoPreferNative(void)
{
    NSData *q = makeQualities(20, 50);
    NSArray *rls = makeUniformLengths(20, 50);
    NSArray *rcs = makeRevcompFlags(20, NO);
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                                  options:@{@"preferNative": @NO}
                                                    error:&err];
    PASS(enc != nil, "preferNative=NO encode succeeds");
    if (!enc) return;
    const uint8_t *bytes = (const uint8_t *)enc.bytes;
    PASS(bytes[4] == 1, "preferNative=NO forces V1 (version byte == 1)");
}

static void testV2NativeEncodeDecode(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) {
        fprintf(stderr,
            "  testV2NativeEncodeDecode: skipping — native backend unavailable "
            "(backendName=%s)\n", [backend UTF8String]);
        return;
    }

    NSData *q = makeQualities(50, 80);
    NSArray *rls = makeUniformLengths(50, 80);
    NSArray *rcs = makeRevcompFlags(50, NO);
    NSError *err = nil;

    // Baseline V1 for comparison.
    NSData *encV1 = [TTIOFqzcompNx16Z encodeWithQualities:q
                                                readLengths:rls
                                               revcompFlags:rcs
                                                      error:&err];
    PASS(encV1 != nil, "V1 baseline encode succeeds");

    err = nil;
    NSData *encV2 = [TTIOFqzcompNx16Z encodeWithQualities:q
                                                readLengths:rls
                                               revcompFlags:rcs
                                                    options:@{@"preferNative": @YES}
                                                      error:&err];
    PASS(encV2 != nil, "V2 native encode succeeds");
    if (!encV2) {
        if (err) fprintf(stderr, "    error: %s\n",
                         [[err localizedDescription] UTF8String]);
        return;
    }
    const uint8_t *bytes = (const uint8_t *)encV2.bytes;
    PASS(bytes[0] == 'M' && bytes[1] == '9' && bytes[2] == '4' && bytes[3] == 'Z',
         "V2 magic bytes are M94Z");
    PASS(bytes[4] == 2, "V2 version byte == 2");

    err = nil;
    NSDictionary *decV2 = [TTIOFqzcompNx16Z decodeData:encV2 revcompFlags:rcs error:&err];
    PASS(decV2 != nil, "V2 decode succeeds");
    if (!decV2) {
        if (err) fprintf(stderr, "    error: %s\n",
                         [[err localizedDescription] UTF8String]);
        return;
    }
    PASS([decV2[@"qualities"] isEqualToData:q],
         "V2 round-trip matches input qualities");

    // V1 and V2 decode to same qualities.
    NSDictionary *decV1 = [TTIOFqzcompNx16Z decodeData:encV1 revcompFlags:rcs error:nil];
    if (decV1) {
        PASS([decV1[@"qualities"] isEqualToData:decV2[@"qualities"]],
             "V1 and V2 decode to identical qualities");
    }
}

static void testV2NativeUnaligned(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) return;

    // Length 7 forces pad_count=1; 1 read of 7.
    NSData *q = makeQualities(1, 7);
    NSArray *rls = makeUniformLengths(1, 7);
    NSArray *rcs = makeRevcompFlags(1, NO);
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                                  options:@{@"preferNative": @YES}
                                                    error:&err];
    PASS(enc != nil, "V2 unaligned encode succeeds");
    if (!enc) return;
    PASS(((const uint8_t *)enc.bytes)[4] == 2, "V2 unaligned: version byte == 2");

    NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rcs error:&err];
    PASS(dec != nil, "V2 unaligned decode succeeds");
    if (dec) {
        PASS([dec[@"qualities"] isEqualToData:q],
             "V2 unaligned round-trip matches");
    }
}

static void testV2NativeMultiReadRevcomp(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) return;

    NSData *q = makeQualities(8, 60);
    NSArray *rls = makeUniformLengths(8, 60);
    NSArray *rcs = makeRevcompFlags(8, YES);  // alternating 0/1
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                                  options:@{@"preferNative": @YES}
                                                    error:&err];
    PASS(enc != nil, "V2 multi-read+revcomp encode succeeds");
    if (!enc) return;
    NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rcs error:&err];
    PASS(dec != nil, "V2 multi-read+revcomp decode succeeds");
    if (dec) {
        PASS([dec[@"qualities"] isEqualToData:q],
             "V2 multi-read+revcomp round-trip matches");
    }
}

static void testV1V2HeaderShape(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) return;

    NSData *q = makeQualities(4, 32);
    NSArray *rls = makeUniformLengths(4, 32);
    NSArray *rcs = makeRevcompFlags(4, NO);
    NSError *err = nil;

    NSData *encV1 = [TTIOFqzcompNx16Z encodeWithQualities:q
                                                readLengths:rls
                                               revcompFlags:rcs
                                                      error:&err];
    NSData *encV2 = [TTIOFqzcompNx16Z encodeWithQualities:q
                                                readLengths:rls
                                               revcompFlags:rcs
                                                    options:@{@"preferNative": @YES}
                                                      error:&err];
    PASS(encV1 != nil && encV2 != nil, "V1 + V2 encode both succeed");
    if (!encV1 || !encV2) return;

    // Both share the magic + flags byte at offset 5; only version byte differs.
    const uint8_t *b1 = (const uint8_t *)encV1.bytes;
    const uint8_t *b2 = (const uint8_t *)encV2.bytes;
    PASS(memcmp(b1, b2, 4) == 0, "V1/V2 magic bytes identical");
    PASS(b1[4] == 1 && b2[4] == 2, "V1 version=1, V2 version=2");
    PASS(b1[5] == b2[5], "V1/V2 flags byte identical (same pad_count)");
}

// ── Native streaming decode (Task 26c) ─────────────────────────────
//
// The streaming decode path (z_decode_v2_via_native_streaming in
// TTIOFqzcompNx16Z.m) is gated on TTIO_M94Z_USE_NATIVE_STREAMING env
// var.  This test sets the env var, encodes a V2 blob, and verifies
// round-trip correctness.  Per-symbol C-callback overhead means this
// is infrastructure only — see Task 26c report for the perf reality.
static void testV2NativeStreamingRoundTrip(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) {
        // Only meaningful when the native library is linked in.
        return;
    }

    // Save, set, restore env var so we don't leak between tests.
    const char *saved = getenv("TTIO_M94Z_USE_NATIVE_STREAMING");
    NSString *savedStr = saved ? [NSString stringWithUTF8String:saved] : nil;
    setenv("TTIO_M94Z_USE_NATIVE_STREAMING", "1", 1);

    NSData *q = makeQualities(50, 80);
    NSArray *rls = makeUniformLengths(50, 80);
    NSArray *rcs = makeRevcompFlags(50, YES);
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                                  options:@{@"preferNative": @YES}
                                                    error:&err];
    PASS(enc != nil, "V2 streaming-mode encode succeeds");
    if (enc) {
        const uint8_t *b = (const uint8_t *)enc.bytes;
        PASS(b[4] == 2, "V2 version byte == 2");

        err = nil;
        NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc
                                            revcompFlags:rcs
                                                   error:&err];
        PASS(dec != nil, "V2 streaming-mode decode succeeds");
        if (dec) {
            PASS([dec[@"qualities"] isEqualToData:q],
                 "V2 native streaming round-trip matches input qualities");
        }
    }

    // Restore env var.
    if (savedStr) setenv("TTIO_M94Z_USE_NATIVE_STREAMING",
                          [savedStr UTF8String], 1);
    else          unsetenv("TTIO_M94Z_USE_NATIVE_STREAMING");
}

static void testV2NativeStreamingFallsBackOnUnset(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) return;

    // Default behaviour (env var unset) must use the pure-ObjC V2
    // decoder.  Round-trip must still succeed.
    unsetenv("TTIO_M94Z_USE_NATIVE_STREAMING");

    NSData *q = makeQualities(20, 30);
    NSArray *rls = makeUniformLengths(20, 30);
    NSArray *rcs = makeRevcompFlags(20, NO);
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                                  options:@{@"preferNative": @YES}
                                                    error:&err];
    PASS(enc != nil, "V2 encode (streaming env unset) succeeds");
    if (enc) {
        err = nil;
        NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc
                                            revcompFlags:rcs
                                                   error:&err];
        PASS(dec != nil, "V2 decode (streaming env unset) succeeds");
        if (dec) {
            PASS([dec[@"qualities"] isEqualToData:q],
                 "V2 round-trip with streaming env unset matches input");
        }
    }
}

void testM94ZV2Dispatch(void);
void testM94ZV2Dispatch(void)
{
    testV1DefaultEncode();
    testV1ExplicitNoPreferNative();
    testV2NativeEncodeDecode();
    testV2NativeUnaligned();
    testV2NativeMultiReadRevcomp();
    testV1V2HeaderShape();
    testV2NativeStreamingRoundTrip();
    testV2NativeStreamingFallsBackOnUnset();
}
