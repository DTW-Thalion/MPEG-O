/*
 * TestMultiRecipientXLang — FD-1 Phase A-4 cross-language conformance.
 *
 * Asserts ObjC's recipient-block codec produces the shared golden bytes in
 * conformance/multi_recipient/vectors.json (the same file Python and Java
 * assert against). All three == golden ⇒ all three byte-equal.
 *
 * Fully data-driven: the vector inputs AND expected hex are read from the
 * JSON via NSJSONSerialization.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOEncryptedTransport.h"
#import "Transport/TTIOEncryptedTransport+Conformance.h"

// ── helpers ──────────────────────────────────────────────────────────

static NSString *dataToHex(NSData *d) {
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSData *hexToData(NSString *h) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < h.length; i += 2) {
        unsigned int byte = 0;
        sscanf([[h substringWithRange:NSMakeRange(i, 2)] UTF8String], "%02x", &byte);
        uint8_t v = (uint8_t)byte;
        [d appendBytes:&v length:1];
    }
    return d;
}

/** {"fill": "0x22", "len": 1568} -> NSData. */
static NSData *fillData(NSDictionary *spec) {
    NSUInteger len = [spec[@"len"] unsignedIntegerValue];
    unsigned int fill = 0;
    sscanf([spec[@"fill"] UTF8String], "%x", &fill);
    uint8_t *buf = malloc(len ?: 1);
    memset(buf, (int)fill, len);
    NSData *d = [NSData dataWithBytes:buf length:len];
    free(buf);
    return d;
}

/** Build the encodeRecipientBlock input array from a vector's
 *  additional_recipients JSON. */
static NSArray<NSDictionary *> *additionalFor(NSDictionary *vector) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *r in vector[@"additional_recipients"]) {
        [out addObject:@{
            @"recipientId": r[@"recipient_id"],
            @"kekAlgorithm": r[@"kek_algorithm"],
            @"wrappedDek": fillData(r[@"wrapped_dek"]),
        }];
    }
    return out;
}

/** Walk up from the cwd to locate the shared golden vectors. */
static NSString *vectorsPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [fm currentDirectoryPath];
    for (int i = 0; i < 6 && dir.length; i++) {
        NSString *cand = [dir stringByAppendingPathComponent:
                          @"conformance/multi_recipient/vectors.json"];
        if ([fm fileExistsAtPath:cand]) return cand;
        dir = [dir stringByDeletingLastPathComponent];
    }
    return nil;
}

// ── test ─────────────────────────────────────────────────────────────

void testMultiRecipientXLang(void)
{
    NSString *path = vectorsPath();
    PASS(path != nil, "conformance/multi_recipient/vectors.json located");
    if (!path) return;

    NSData *raw = [NSData dataWithContentsOfFile:path];
    NSError *jerr = nil;
    NSDictionary *doc = [NSJSONSerialization JSONObjectWithData:raw
                                                        options:0 error:&jerr];
    PASS([doc isKindOfClass:[NSDictionary class]], "vectors.json parsed");

    NSArray<NSDictionary *> *vectors = doc[@"vectors"];
    PASS(vectors.count == 5, "five golden vectors present");

    for (NSDictionary *v in vectors) {
        NSString *name = v[@"name"];
        NSArray<NSDictionary *> *additional = additionalFor(v);

        // (a) encode == golden recipient_block_hex
        NSData *block = [TTIOEncryptedTransport
                         ttioConformanceEncodeRecipientBlock:additional];
        NSString *golden = v[@"recipient_block_hex"];
        PASS([dataToHex(block) isEqualToString:golden],
             "%s: recipient block encodes to golden bytes", name.UTF8String);

        // (b) decode(golden) round-trips to the same recipient list
        NSArray<NSDictionary *> *decoded = [TTIOEncryptedTransport
                         ttioConformanceDecodeRecipientBlock:hexToData(golden)];
        PASS(decoded.count == additional.count,
             "%s: decoded recipient count", name.UTF8String);
        BOOL allMatch = (decoded.count == additional.count);
        for (NSUInteger i = 0; i < decoded.count && allMatch; i++) {
            NSDictionary *got = decoded[i], *want = additional[i];
            if (![got[@"recipientId"] isEqual:want[@"recipientId"]]
                || ![got[@"kekAlgorithm"] isEqual:want[@"kekAlgorithm"]]
                || ![got[@"wrappedDek"] isEqualToData:want[@"wrappedDek"]]) {
                allMatch = NO;
            }
        }
        PASS(allMatch, "%s: recipient block round-trips byte-identically",
             name.UTF8String);
    }
}
