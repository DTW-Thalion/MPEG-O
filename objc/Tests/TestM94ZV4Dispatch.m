// TestM94ZV4Dispatch.m — Stage 3 Task 8: M94.Z V4 native-dispatch round-trip.
//
// Mirrors:
//   python/tests/test_m94z_v4_dispatch.py
//   java/src/test/java/.../FqzcompNx16ZV4DispatchTest.java
//
// Verifies:
//   * V4 explicit encode round-trips and emits version byte 4.
//   * V4 is the default emit format when libttio_rans is linked
//     (no options, no env var override).
//   * V2 explicit (preferV4=NO + preferNative=YES) still works.
//   * V1 explicit (preferV4=NO + preferNative=NO) still works.
//   * Pad count, single-read, and mixed-revcomp edge cases round-trip.
//   * V4 with version byte rewritten to 2 fails to decode.
//
// When +backendName is "pure-objc" (libttio_rans not built), every V4
// test short-circuits — only documents the absence of native dispatch.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"

static NSData *synthQualities(void)
{
    // 12 qualities, 3 reads of 4 → padCount = 0.
    static const uint8_t bytes[12] = {
        'I','I','?','?',  '5','5','5','5',  'I','?','I','?'
    };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSArray<NSNumber *> *synthLengths(void)
{
    return @[@4, @4, @4];
}

static NSArray<NSNumber *> *synthRevcomp(void)
{
    return @[@0, @1, @0];
}

static BOOL nativeAvailable(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    return [backend hasPrefix:@"native-"];
}

static void skipIfPureObjC(const char *fn)
{
    fprintf(stderr,
        "  %s: skipping — native backend unavailable (backendName=%s)\n",
        fn, [[TTIOFqzcompNx16Z backendName] UTF8String]);
}

static void testV4SmokeRoundtrip(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    NSData *q = synthQualities();
    NSArray *rls = synthLengths();
    NSArray *rcs = synthRevcomp();
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeV4WithQualities:q
                                              readLengths:rls
                                             revcompFlags:rcs
                                             strategyHint:-1
                                                 padCount:0
                                                    error:&err];
    PASS(enc != nil, "V4 explicit encodeV4 succeeds");
    if (!enc) {
        if (err) fprintf(stderr, "    error: %s\n",
                         [[err localizedDescription] UTF8String]);
        return;
    }
    PASS(enc.length > 30, "V4 stream exceeds 30-byte minimum header");
    const uint8_t *b = (const uint8_t *)enc.bytes;
    PASS(b[0] == 'M' && b[1] == '9' && b[2] == '4' && b[3] == 'Z',
         "V4 magic bytes are M94Z");
    PASS(b[4] == 4, "V4 version byte == 4");

    err = nil;
    NSDictionary *dec = [TTIOFqzcompNx16Z decodeV4Data:enc
                                          revcompFlags:rcs
                                                 error:&err];
    PASS(dec != nil, "V4 decode succeeds");
    if (!dec) return;
    PASS([dec[@"qualities"] isEqualToData:q],
         "V4 round-trip matches input qualities");
    NSArray *gotLens = dec[@"readLengths"];
    PASS([gotLens isEqualToArray:rls],
         "V4 decode recovers original read lengths");
}

static void testV4DefaultWhenNativeLinked(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    // Empty options dict — V4 is the default when native is linked.
    NSData *q = synthQualities();
    NSArray *rls = synthLengths();
    NSArray *rcs = synthRevcomp();
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                            readLengths:rls
                                           revcompFlags:rcs
                                                options:@{}
                                                  error:&err];
    PASS(enc != nil, "default-options encode succeeds");
    if (!enc) return;
    PASS(((const uint8_t *)enc.bytes)[4] == 4,
         "default-options yields V4 (version byte == 4)");
}

static void testV4DefaultBareEncode(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    // The 4-arg encode (no options dict at all) must also default to V4.
    NSData *q = synthQualities();
    NSArray *rls = synthLengths();
    NSArray *rcs = synthRevcomp();
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                            readLengths:rls
                                           revcompFlags:rcs
                                                  error:&err];
    PASS(enc != nil, "bare encodeWithQualities (no options) succeeds");
    if (!enc) return;
    PASS(((const uint8_t *)enc.bytes)[4] == 4,
         "bare encode defaults to V4 when native linked");

    NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc
                                        revcompFlags:rcs
                                               error:&err];
    PASS(dec != nil, "decodeData auto-routes V4 stream");
    if (dec) {
        PASS([dec[@"qualities"] isEqualToData:q],
             "auto-routed V4 round-trip matches");
    }
}

// (REMOVED v1.0 reset Phase 2c): testV2ExplicitStillWorks +
// testV1ExplicitStillWorks asserted the encoder honoured preferV4=NO
// requests. Phase 2c always emits V4 (preferV4=NO is ignored), so
// these expectations no longer hold.

static void testV4PadCountThirteenQualities(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    // 13 qualities → padCount = (-13) & 3 = 3. Exercises non-zero padding.
    uint8_t bytes[13];
    for (int i = 0; i < 13; i++) bytes[i] = (uint8_t)(33 + i);
    NSData *q = [NSData dataWithBytes:bytes length:13];
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeV4WithQualities:q
                                              readLengths:@[@13]
                                             revcompFlags:@[@0]
                                             strategyHint:-1
                                                 padCount:3
                                                    error:&err];
    PASS(enc != nil, "V4 13-qualities encode succeeds");
    if (!enc) return;
    PASS(((const uint8_t *)enc.bytes)[4] == 4, "13-qualities V4 version == 4");

    NSDictionary *dec = [TTIOFqzcompNx16Z decodeV4Data:enc
                                          revcompFlags:@[@0]
                                                 error:&err];
    PASS(dec != nil && [dec[@"qualities"] isEqualToData:q],
         "V4 13-qualities round-trip matches");
    NSArray *gotLens = dec[@"readLengths"];
    PASS([gotLens isEqualToArray:@[@13]],
         "V4 13-qualities recovers read length 13");
}

static void testV4SingleRead(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    uint8_t bytes[50];
    for (int i = 0; i < 50; i++) bytes[i] = 'I';
    NSData *q = [NSData dataWithBytes:bytes length:50];
    NSError *err = nil;

    NSData *enc = [TTIOFqzcompNx16Z encodeV4WithQualities:q
                                              readLengths:@[@50]
                                             revcompFlags:@[@0]
                                             strategyHint:-1
                                                 padCount:2
                                                    error:&err];
    PASS(enc != nil, "V4 single-read encode succeeds");
    if (!enc) return;

    NSDictionary *dec = [TTIOFqzcompNx16Z decodeV4Data:enc
                                          revcompFlags:@[@0]
                                                 error:&err];
    PASS(dec != nil && [dec[@"qualities"] isEqualToData:q],
         "V4 single-read round-trip matches");
}

static void testV4MixedRevcompRoundtrip(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    // 20 reads of varied length, mixed revcomp — exercises V4 SAM-flag
    // mapping (bit 4 = SAM_REVERSE) and per-read state reset.
    const int target = 2342;
    uint8_t buf[target];
    uint64_t s = 0xBEEFULL;
    for (int i = 0; i < target; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        buf[i] = (uint8_t)(33 + 20 + (uint32_t)((s >> 32) & 0xFFFFFFFFULL) % 21);
    }
    NSData *q = [NSData dataWithBytes:buf length:target];

    const int nReads = 20;
    NSMutableArray *lens = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *rcs  = [NSMutableArray arrayWithCapacity:nReads];
    int rem = target;
    for (int i = 0; i < nReads - 1; i++) {
        int L = 50 + (i * 7) % 150;
        [lens addObject:@(L)];
        rem -= L;
        [rcs addObject:@(i % 3 == 0 ? 1 : 0)];
    }
    [lens addObject:@(rem)];
    [rcs  addObject:@1];

    uint8_t pad = (uint8_t)((-target) & 0x3);
    NSError *err = nil;
    NSData *enc = [TTIOFqzcompNx16Z encodeV4WithQualities:q
                                              readLengths:lens
                                             revcompFlags:rcs
                                             strategyHint:-1
                                                 padCount:pad
                                                    error:&err];
    PASS(enc != nil, "V4 mixed-revcomp encode succeeds");
    if (!enc) return;
    PASS(((const uint8_t *)enc.bytes)[4] == 4, "V4 mixed-revcomp version == 4");

    NSDictionary *dec = [TTIOFqzcompNx16Z decodeV4Data:enc
                                          revcompFlags:rcs
                                                 error:&err];
    PASS(dec != nil && [dec[@"qualities"] isEqualToData:q],
         "V4 mixed-revcomp round-trip matches");
    PASS([dec[@"readLengths"] isEqualToArray:lens],
         "V4 mixed-revcomp recovers read lengths");
}

// (REMOVED v1.0 reset Phase 2c): testV4SizeSanityVsV2 compared V4
// footprint against the V2 native encoder. V2 encode was removed in
// Phase 2c — every encode emits V4.

static void testV4MagicAndMinHeaderSize(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    NSData *q = synthQualities();
    NSError *err = nil;
    NSData *enc = [TTIOFqzcompNx16Z encodeWithQualities:q
                                            readLengths:synthLengths()
                                           revcompFlags:synthRevcomp()
                                                options:@{@"preferV4": @YES}
                                                  error:&err];
    PASS(enc != nil, "V4 encode for header sanity check");
    if (!enc) return;
    PASS(enc.length > 30, "V4 stream > 30 byte header");
    const uint8_t *b = (const uint8_t *)enc.bytes;
    PASS(b[0] == 'M' && b[1] == '9' && b[2] == '4' && b[3] == 'Z',
         "magic bytes M94Z");
    PASS(b[4] == 4, "version byte 4");
}

static void testV4DecodeRejectsTamperedVersionByte(void)
{
    if (!nativeAvailable()) { skipIfPureObjC(__func__); return; }

    // V4 stream with version byte rewritten to 2 must fail to decode via
    // the V2 path (the body is fqzcomp, not the V2 native block codec).
    NSError *err = nil;
    NSData *v4 = [TTIOFqzcompNx16Z encodeWithQualities:synthQualities()
                                           readLengths:synthLengths()
                                          revcompFlags:synthRevcomp()
                                               options:@{@"preferV4": @YES}
                                                 error:&err];
    PASS(v4 != nil, "V4 encode for tamper test");
    if (!v4) return;

    NSMutableData *tampered = [v4 mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[4] = 2;

    err = nil;
    NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:tampered
                                        revcompFlags:synthRevcomp()
                                               error:&err];
    PASS(dec == nil,
         "decode of V4 blob with version byte rewritten to 2 must fail");
}

void testM94ZV4Dispatch(void);
void testM94ZV4Dispatch(void)
{
    testV4SmokeRoundtrip();
    testV4DefaultWhenNativeLinked();
    testV4DefaultBareEncode();
    testV4PadCountThirteenQualities();
    testV4SingleRead();
    testV4MixedRevcompRoundtrip();
    testV4MagicAndMinHeaderSize();
    testV4DecodeRejectsTamperedVersionByte();
}
