// TestPackedReference.m
//
// Objective-C normative tests for the packed reference-chromosome
// layout (2-bit body + run mask). Mirrors
// python/tests/test_packed_reference.py and pins the cross-language
// golden stream byte-for-byte.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Genomics/TTIOPackedReference.h"

#include <string.h>

static NSData *prBytesOf(const char *s)
{
    return [NSData dataWithBytes:s length:strlen(s)];
}

static NSData *prRepeated(const char *unit, NSUInteger times)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:strlen(unit) * times];
    for (NSUInteger i = 0; i < times; i++) {
        [d appendBytes:unit length:strlen(unit)];
    }
    return d;
}

void testPackedReference(void)
{
    // ── Round trips over the shared edge-case corpus ────────────────
    NSMutableData *nRuns = [prRepeated("N", 507) mutableCopy];
    [nRuns appendData:prRepeated("ACGT", 250)];
    [nRuns appendData:prRepeated("N", 33)];
    NSDictionary<NSString *, NSData *> *cases = @{
        @"empty":                  [NSData data],
        @"pure_acgt":              prBytesOf("ACGTACGTACGT"),
        @"all_n":                  prRepeated("N", 1000),
        @"n_runs_both_ends":       nRuns,
        @"iupac_mixed":            prRepeated("ACGTRYSWKMBDHVNacgt", 97),
        @"single_base":            prBytesOf("G"),
        @"single_exception":       prBytesOf("n"),
        @"trailing_partial_byte":  prBytesOf("ACGTA"),
        @"alternating_exceptions": prRepeated("ANANANANAN", 55),
    };
    for (NSString *name in [cases.allKeys
            sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *data = cases[name];
        NSData *enc = [TTIOPackedReference encode:data];
        NSError *err = nil;
        NSData *dec = [TTIOPackedReference decode:enc error:&err];
        PASS(dec != nil && [dec isEqualToData:data],
             "round trip: %s", name.UTF8String);
    }

    // ── Golden stream — byte-exact pin shared with Python
    //    test_packed_reference.py::test_golden_stream_bytes and Java
    //    PackedReferenceTest.goldenStreamBytes. ─────────────────────
    NSMutableData *goldenInput = [prRepeated("N", 7) mutableCopy];
    [goldenInput appendData:prBytesOf("ACGTACGTGG")];
    [goldenInput appendData:prBytesOf("n")];
    [goldenInput appendData:prBytesOf("TTT")];
    static const uint8_t goldenBytes[] = {
        0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07,
        0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x01,
        0x4e, 0x4e, 0x4e, 0x4e, 0x4e, 0x4e, 0x4e, 0x6e,
        0x1b, 0x1b, 0xaf, 0xc0,
    };
    NSData *golden = [NSData dataWithBytes:goldenBytes
                                    length:sizeof(goldenBytes)];
    PASS([[TTIOPackedReference encode:goldenInput] isEqualToData:golden],
         "encode matches the cross-language golden stream");
    NSError *gerr = nil;
    NSData *gdec = [TTIOPackedReference decode:golden error:&gerr];
    PASS(gdec != nil && [gdec isEqualToData:goldenInput],
         "golden stream decodes to the input");

    // ── The pack decision ───────────────────────────────────────────
    PASS([TTIOPackedReference packableFraction:[NSData data]] == 1.0,
         "empty input counts as fully packable");
    PASS([TTIOPackedReference packableFraction:prBytesOf("acgt")] == 0.0,
         "soft-masked bytes are not packable");
    NSString *dsName = nil;
    NSData *big = prRepeated("ACGT", 4096);
    NSData *payload = [TTIOPackedReference payloadForSequence:big
                                                  datasetName:&dsName];
    PASS([dsName isEqualToString:@"data_packed"] && payload.length < big.length,
         "a pure-ACGT sequence packs to data_packed");
    NSData *soft = prRepeated("acgt", 4096);
    payload = [TTIOPackedReference payloadForSequence:soft datasetName:&dsName];
    PASS([dsName isEqualToString:@"data"] && [payload isEqualToData:soft],
         "a soft-masked sequence keeps the raw data layout");

    // ── Malformed streams ───────────────────────────────────────────
    NSError *merr = nil;
    PASS([TTIOPackedReference decode:[NSData data] error:&merr] == nil,
         "empty stream is rejected");
    NSMutableData *bad =
        [[TTIOPackedReference encode:prBytesOf("ACGT")] mutableCopy];
    ((uint8_t *)bad.mutableBytes)[0] = 0x7F;
    merr = nil;
    PASS([TTIOPackedReference decode:bad error:&merr] == nil,
         "unknown version byte is rejected");
}
