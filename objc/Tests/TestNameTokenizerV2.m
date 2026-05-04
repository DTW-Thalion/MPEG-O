// TestNameTokenizerV2.m -- round-trip + invalid-input tests for name_tok v2.
//
// Mirrors:
//   python/tests/test_name_tok_v2_native.py
//   java/src/test/java/.../NameTokenizerV2Test.java
//
// SPDX-License-Identifier: LGPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIONameTokenizerV2.h"

static void testRoundTrip(void) {
    NSArray *names = @[@"EAS220_R1:8:1:0:1234",
                       @"EAS220_R1:8:1:0:1234",
                       @"EAS220_R1:8:1:0:1235"];
    NSData *blob = [TTIONameTokenizerV2 encodeNames:names];
    PASS(blob != nil, "encode produced data");
    PASS([blob length] >= 12, "blob has at least 12-byte header");

    const uint8_t *bb = (const uint8_t *)[blob bytes];
    PASS(bb[0] == 'N' && bb[1] == 'T' && bb[2] == 'K' && bb[3] == '2',
         "magic bytes NTK2");

    NSError *err = nil;
    NSArray *decoded = [TTIONameTokenizerV2 decodeData:blob error:&err];
    PASS(err == nil, "no decode error");
    PASS([decoded isEqualToArray:names], "round-trip equals input");
}

static void testTwoBlocks(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (int i = 0; i < 4097; i++) {
        [names addObject:[NSString stringWithFormat:@"R:1:%d", i]];
    }
    NSData *blob = [TTIONameTokenizerV2 encodeNames:names];
    NSError *err = nil;
    NSArray *decoded = [TTIONameTokenizerV2 decodeData:blob error:&err];
    PASS(err == nil, "no error on 4097-name input");
    PASS([decoded isEqualToArray:names], "4097-name round-trip");
}

static void testBadMagic(void) {
    uint8_t bad[12] = {'X','X','X','X', 0x01, 0x00, 0,0,0,0, 0,0};
    NSData *blob = [NSData dataWithBytes:bad length:12];
    NSError *err = nil;
    NSArray *decoded = [TTIONameTokenizerV2 decodeData:blob error:&err];
    PASS(decoded == nil, "decode returns nil on bad magic");
    PASS(err != nil, "error set on bad magic");
}

void testNameTokenizerV2(void);
void testNameTokenizerV2(void) {
    testRoundTrip();
    testTwoBlocks();
    testBadMagic();
}
