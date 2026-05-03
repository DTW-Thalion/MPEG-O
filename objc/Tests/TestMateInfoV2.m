// TestMateInfoV2.m — round-trip + invalid-input tests for mate_info v2.
//
// Mirrors:
//   python/tests/test_mate_info_v2_native.py
//   java/src/test/java/global/thalion/ttio/codecs/MateInfoV2Test.java
//
// SPDX-License-Identifier: LGPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOMateInfoV2.h"

static void testRoundTripMixed(void) {
    NSUInteger n = 1000;
    NSMutableData *mc = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *mp = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *ts = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *oc = [NSMutableData dataWithLength:n * sizeof(uint16_t)];
    NSMutableData *op = [NSMutableData dataWithLength:n * sizeof(int64_t)];

    int32_t  *mcp = (int32_t  *)[mc mutableBytes];
    int64_t  *mpp = (int64_t  *)[mp mutableBytes];
    int32_t  *tsp = (int32_t  *)[ts mutableBytes];
    uint16_t *ocp = (uint16_t *)[oc mutableBytes];
    int64_t  *opp = (int64_t  *)[op mutableBytes];

    srand(42);
    for (NSUInteger i = 0; i < n; i++) {
        ocp[i] = (uint16_t)(rand() % 24);
        opp[i] = (int64_t)(rand() % 100000000);
        tsp[i] = (rand() % 1000) - 500;
        int dice = rand() % 10;
        if (dice < 8) {
            mcp[i] = (int32_t)ocp[i];
            mpp[i] = opp[i] + (rand() % 1000) - 500;
        } else if (dice < 9) {
            mcp[i] = (int32_t)((ocp[i] + 1) % 24);
            mpp[i] = (int64_t)(rand() % 100000000);
        } else {
            mcp[i] = -1;
            mpp[i] = 0;
        }
    }

    NSError *error = nil;
    NSData *encoded = [TTIOMateInfoV2 encodeMateChromIds:mc
                                          matePositions:mp
                                        templateLengths:ts
                                            ownChromIds:oc
                                           ownPositions:op
                                                  error:&error];
    PASS(encoded != nil, "encode succeeded");
    if (!encoded) return;
    PASS([encoded length] > 34, "encoded > header size");

    const uint8_t *bytes = (const uint8_t *)[encoded bytes];
    PASS(bytes[0] == 'M' && bytes[1] == 'I' && bytes[2] == 'v' && bytes[3] == '2',
         "magic bytes MIv2");

    NSData *outMc = nil, *outMp = nil, *outTs = nil;
    BOOL ok = [TTIOMateInfoV2 decodeData:encoded
                             ownChromIds:oc
                            ownPositions:op
                               nRecords:n
                        outMateChromIds:&outMc
                       outMatePositions:&outMp
                     outTemplateLengths:&outTs
                                  error:&error];
    PASS(ok, "decode succeeded");
    if (!ok) return;

    PASS(memcmp([mc bytes], [outMc bytes], n * sizeof(int32_t)) == 0,
         "mate_chrom_ids round-trip exact");
    PASS(memcmp([mp bytes], [outMp bytes], n * sizeof(int64_t)) == 0,
         "mate_positions round-trip exact");
    PASS(memcmp([ts bytes], [outTs bytes], n * sizeof(int32_t)) == 0,
         "template_lengths round-trip exact");
}

static void testInvalidMateChromRejected(void) {
    int32_t  mc_arr[1] = {-2};
    int64_t  mp_arr[1] = {0};
    int32_t  ts_arr[1] = {0};
    uint16_t oc_arr[1] = {0};
    int64_t  op_arr[1] = {0};

    NSData *mcD = [NSData dataWithBytes:mc_arr length:sizeof(mc_arr)];
    NSData *mpD = [NSData dataWithBytes:mp_arr length:sizeof(mp_arr)];
    NSData *tsD = [NSData dataWithBytes:ts_arr length:sizeof(ts_arr)];
    NSData *ocD = [NSData dataWithBytes:oc_arr length:sizeof(oc_arr)];
    NSData *opD = [NSData dataWithBytes:op_arr length:sizeof(op_arr)];

    NSError *error = nil;
    NSData *encoded = [TTIOMateInfoV2 encodeMateChromIds:mcD
                                          matePositions:mpD
                                        templateLengths:tsD
                                            ownChromIds:ocD
                                           ownPositions:opD
                                                  error:&error];
    PASS(encoded == nil, "encode rejected mate_chrom_id < -1");
    PASS(error != nil, "error set on rejection");
}

void testMateInfoV2(void);
void testMateInfoV2(void) {
    testRoundTripMixed();
    testInvalidMateChromRejected();
}
