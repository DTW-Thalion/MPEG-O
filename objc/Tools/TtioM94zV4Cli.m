/*
 * TtioM94zV4Cli — tiny CLI mirroring Java's M94zV4Cli for cross-language
 * V4 byte-equality tests.
 *
 * Reads qual.bin (raw uint8 quality bytes), lens.bin (uint32 LE per-read
 * lengths), flags.bin (uint32 LE per-read SAM flags — bit 4 = SAM_REVERSE),
 * V4-encodes via libttio_rans, writes the full M94Z V4 stream to out.fqz.
 *
 * Usage: TtioM94zV4Cli qual.bin lens.bin flags.bin out.fqz
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Codecs/TTIOFqzcompNx16Z.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 5) {
            fprintf(stderr,
                "usage: %s qual.bin lens.bin flags.bin out.fqz\n", argv[0]);
            return 1;
        }
        NSData *qualities = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *lensBlob  = [NSData dataWithContentsOfFile:@(argv[2])];
        NSData *flagsBlob = [NSData dataWithContentsOfFile:@(argv[3])];
        if (!qualities || !lensBlob || !flagsBlob) {
            fprintf(stderr,
                "TtioM94zV4Cli: failed to read inputs\n");
            return 2;
        }

        size_t nReads = lensBlob.length / 4;
        const uint32_t *lensArr  = (const uint32_t *)lensBlob.bytes;
        const uint32_t *flagsArr = (const uint32_t *)flagsBlob.bytes;
        NSMutableArray<NSNumber *> *lens =
            [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray<NSNumber *> *rev =
            [NSMutableArray arrayWithCapacity:nReads];
        for (size_t i = 0; i < nReads; i++) {
            [lens addObject:@(lensArr[i])];
            [rev  addObject:@((flagsArr[i] & 16) != 0 ? 1 : 0)];
        }

        // pad_count = (-num_qualities) & 3, matching Python and Java
        // top-level dispatch (TTIOFqzcompNx16Z.m around line 1783).
        uint8_t padCount = (uint8_t)((-(NSInteger)qualities.length) & 0x3);

        NSError *err = nil;
        NSData *out = [TTIOFqzcompNx16Z encodeV4WithQualities:qualities
                                                  readLengths:lens
                                                 revcompFlags:rev
                                                 strategyHint:-1
                                                     padCount:padCount
                                                        error:&err];
        if (!out) {
            fprintf(stderr, "encodeV4 returned nil: %s\n",
                    [[err localizedDescription] UTF8String]);
            return 3;
        }
        if (![out writeToFile:@(argv[4]) atomically:YES]) {
            fprintf(stderr, "TtioM94zV4Cli: failed to write %s\n", argv[4]);
            return 4;
        }
        fprintf(stderr,
            "ObjC V4: %zu qualities -> %zu bytes (B/qual=%.4f)\n",
            (size_t)qualities.length, (size_t)out.length,
            (double)out.length / qualities.length);
    }
    return 0;
}
