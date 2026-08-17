/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * The FDZ1 block API: header, per-block encode, block table and
 * block-wise decode agree with the whole-stream encode/decode.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFloatDeltaZstd.h"

static NSData *fdzValues(NSUInteger n, double seed)
{
    NSMutableData *d = [NSMutableData dataWithLength:n * sizeof(double)];
    double *v = d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) v[i] = seed + i * 0.25 + (i % 7) * 1e-3;
    return d;
}

void testFloatDeltaZstdBlocks(void)
{
    @autoreleasepool {
        NSUInteger bs = [TTIOFloatDeltaZstd blockSize];
        PASS(bs == (1u << 20), "fdz blocks: block size 1 Mi values");
        NSData *hdr = [TTIOFloatDeltaZstd headerBytesForValues:12 blocks:1];
        PASS(hdr.length == 22 && memcmp(hdr.bytes, "FDZ1", 4) == 0, "fdz blocks: 22-byte header");

        // 2.5 blocks of values: three blocks, the last short.
        NSUInteger n = bs * 2 + bs / 2;
        NSData *values = fdzValues(n, 100.0);
        NSData *whole = [TTIOFloatDeltaZstd encodeFloat64:values];
        NSMutableData *composed = [NSMutableData dataWithData:[TTIOFloatDeltaZstd headerBytesForValues:n blocks:3]];
        for (NSUInteger k = 0; k < 3; k++) {
            NSUInteger off = k * bs, len = MIN(bs, n - off);
            TTIOFDZEncodedBlock *b = [TTIOFloatDeltaZstd encodeBlock:
                [values subdataWithRange:NSMakeRange(off * 8, len * 8)]];
            [composed appendData:[TTIOFloatDeltaZstd blockBytes:b]];
        }
        PASS([composed isEqualToData:whole], "fdz blocks: header + blocks equal the whole-stream encode (%lu bytes)",
             (unsigned long)whole.length);

        NSError *err = nil;
        __block NSUInteger reads = 0;
        TTIOFDZByteRangeReader reader = ^NSData *(NSUInteger off, NSUInteger count) {
            reads++;
            if (off >= whole.length) return nil;
            return [whole subdataWithRange:NSMakeRange(off, MIN(count, whole.length - off))];
        };
        TTIOFDZBlockTable *t = [TTIOFloatDeltaZstd readBlockTableWithReader:reader error:&err];
        PASS(t != nil && t.nValues == n && t.nBlocks == 3 && t.blockSize == bs,
             "fdz blocks: block table (%s)", [[err localizedDescription] UTF8String] ?: "");
        PASS(reads == 4, "fdz blocks: the table reads the header and three block headers only (%lu)", (unsigned long)reads);
        PASS([t blockValues:0] == bs && [t blockValues:2] == bs / 2, "fdz blocks: block values");
        uint64_t expectOff = 22 + 5;
        BOOL offsetsChain = YES;
        for (NSUInteger k = 0; k < 3; k++) {
            if ([t offsetAt:k] != expectOff) offsetsChain = NO;
            expectOff += [t lengthAt:k] + 5;
        }
        PASS(offsetsChain && expectOff - 5 == whole.length, "fdz blocks: block offsets chain to the stream end");
        BOOL decodeOk = YES;
        for (NSUInteger k = 0; k < 3; k++) {
            NSData *blk = [TTIOFloatDeltaZstd decodeBlock:k table:t reader:reader error:&err];
            NSUInteger off = k * bs, len = [t blockValues:k];
            if (!blk || ![blk isEqualToData:[values subdataWithRange:NSMakeRange(off * 8, len * 8)]]) decodeOk = NO;
        }
        PASS(decodeOk, "fdz blocks: each block decodes to its slice");
        PASS([TTIOFloatDeltaZstd decodeBlock:3 table:t reader:reader error:NULL] == nil, "fdz blocks: block 3 is out of range");
        NSData *all = [TTIOFloatDeltaZstd decodeStream:whole error:&err];
        PASS([all isEqualToData:values], "fdz blocks: whole-stream decode round trip");

        // An empty stream: header only, no blocks.
        NSData *empty = [TTIOFloatDeltaZstd encodeFloat64:[NSData data]];
        TTIOFDZBlockTable *te = [TTIOFloatDeltaZstd readBlockTableWithReader:^NSData *(NSUInteger off, NSUInteger count) {
            return [empty subdataWithRange:NSMakeRange(off, MIN(count, empty.length - off))];
        } error:&err];
        PASS(empty.length == 22 && te != nil && te.nBlocks == 0 && te.nValues == 0, "fdz blocks: empty stream table");
        // A short read fails cleanly.
        NSData *cut = [whole subdataWithRange:NSMakeRange(0, 40)];
        TTIOFDZBlockTable *tc = [TTIOFloatDeltaZstd readBlockTableWithReader:^NSData *(NSUInteger off, NSUInteger count) {
            if (off >= cut.length) return nil;
            return [cut subdataWithRange:NSMakeRange(off, MIN(count, cut.length - off))];
        } error:&err];
        PASS(tc == nil && err != nil, "fdz blocks: truncated stream is an error");
    }
}
