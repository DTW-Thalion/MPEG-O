/*
 * TtioMateInfoV2Cli — tiny CLI mirroring Java's MateInfoV2Cli for
 * cross-language byte-equality tests of the mate_info v2 codec.
 *
 * Reads pre-extracted binary blobs (same shape as the Python
 * extract_mate_triples helper):
 *   mc.bin — int32 LE per-record mate_chrom_ids
 *   mp.bin — int64 LE per-record mate_positions
 *   ts.bin — int32 LE per-record template_lengths
 *   oc.bin — uint16 LE per-record own_chrom_ids
 *   op.bin — int64 LE per-record own_positions
 *
 * Writes the encoded inline_v2 blob to out.bin (or stdout if "-").
 *
 * Usage: TtioMateInfoV2Cli mc.bin mp.bin ts.bin oc.bin op.bin out.bin
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Codecs/TTIOMateInfoV2.h"

#import <stdio.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 7) {
            fprintf(stderr,
                "usage: %s mc.bin mp.bin ts.bin oc.bin op.bin out.bin\n",
                argv[0]);
            fprintf(stderr, "  mc.bin: int32 LE per-record mate_chrom_ids\n");
            fprintf(stderr, "  mp.bin: int64 LE per-record mate_positions\n");
            fprintf(stderr, "  ts.bin: int32 LE per-record template_lengths\n");
            fprintf(stderr, "  oc.bin: uint16 LE per-record own_chrom_ids\n");
            fprintf(stderr, "  op.bin: int64 LE per-record own_positions\n");
            fprintf(stderr, "  out.bin: encoded blob output (or '-' for stdout)\n");
            return 1;
        }

        NSData *mc = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *mp = [NSData dataWithContentsOfFile:@(argv[2])];
        NSData *ts = [NSData dataWithContentsOfFile:@(argv[3])];
        NSData *oc = [NSData dataWithContentsOfFile:@(argv[4])];
        NSData *op = [NSData dataWithContentsOfFile:@(argv[5])];
        if (!mc || !mp || !ts || !oc || !op) {
            fprintf(stderr, "TtioMateInfoV2Cli: failed to read inputs\n");
            return 2;
        }

        NSUInteger n = [mc length] / sizeof(int32_t);
        if ([mp length] != n * sizeof(int64_t) ||
            [ts length] != n * sizeof(int32_t) ||
            [oc length] != n * sizeof(uint16_t) ||
            [op length] != n * sizeof(int64_t)) {
            fprintf(stderr,
                "input length mismatch: n=%lu, mc=%lu, mp=%lu, ts=%lu, oc=%lu, op=%lu\n",
                (unsigned long)n,
                (unsigned long)[mc length], (unsigned long)[mp length],
                (unsigned long)[ts length], (unsigned long)[oc length],
                (unsigned long)[op length]);
            return 1;
        }

        NSError *err = nil;
        NSData *encoded = [TTIOMateInfoV2 encodeMateChromIds:mc
                                               matePositions:mp
                                             templateLengths:ts
                                                 ownChromIds:oc
                                                ownPositions:op
                                                       error:&err];
        if (!encoded) {
            fprintf(stderr, "encode failed: %s\n",
                    [[err localizedDescription] UTF8String]);
            return 3;
        }

        NSString *outPath = @(argv[6]);
        if ([outPath isEqualToString:@"-"]) {
            fwrite([encoded bytes], 1, [encoded length], stdout);
            fflush(stdout);
        } else {
            if (![encoded writeToFile:outPath atomically:YES]) {
                fprintf(stderr, "failed to write %s\n", argv[6]);
                return 4;
            }
        }
        return 0;
    }
}
