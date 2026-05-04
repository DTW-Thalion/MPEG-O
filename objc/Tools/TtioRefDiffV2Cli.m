// TtioRefDiffV2Cli — CLI for ref_diff v2 cross-language byte-equality tests.
//
// Reads pre-extracted binary blobs (same shape as Java RefDiffV2Cli):
//   sequences.bin / offsets.bin (uint64 LE, n+1) / positions.bin (int64 LE, n)
//   cigars.txt (one CIGAR per line) / reference.bin / reference_md5.bin (16 bytes)
//   reference_uri.txt
// Writes the encoded inline_v2 blob to out.bin (or stdout via "-").
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Codecs/TTIORefDiffV2.h"

#import <stdio.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 9) {
            fprintf(stderr,
                "usage: %s sequences.bin offsets.bin positions.bin cigars.txt "
                "reference.bin reference_md5.bin reference_uri.txt out.bin\n",
                argv[0]);
            return 1;
        }

        NSData *sequences = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *offsets   = [NSData dataWithContentsOfFile:@(argv[2])];
        NSData *positions = [NSData dataWithContentsOfFile:@(argv[3])];
        NSString *cigarsText = [NSString stringWithContentsOfFile:@(argv[4])
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
        NSData *reference   = [NSData dataWithContentsOfFile:@(argv[5])];
        NSData *referenceMd5 = [NSData dataWithContentsOfFile:@(argv[6])];
        NSString *referenceUri = [NSString stringWithContentsOfFile:@(argv[7])
                                                            encoding:NSUTF8StringEncoding
                                                               error:NULL];
        if (!sequences || !offsets || !positions || !cigarsText || !reference || !referenceMd5 || !referenceUri) {
            fprintf(stderr, "TtioRefDiffV2Cli: failed to read inputs\n");
            return 2;
        }

        /* Trim trailing whitespace/newline from URI */
        referenceUri = [referenceUri stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([referenceMd5 length] != 16) {
            fprintf(stderr, "reference_md5 must be 16 bytes (got %lu)\n",
                (unsigned long)[referenceMd5 length]);
            return 1;
        }

        NSUInteger n = [positions length] / sizeof(int64_t);
        if ([offsets length] != (n + 1) * sizeof(uint64_t)) {
            fprintf(stderr, "offsets length mismatch: expected %lu bytes, got %lu\n",
                (unsigned long)((n + 1) * sizeof(uint64_t)), (unsigned long)[offsets length]);
            return 1;
        }

        /* Split cigarsText on newlines. Drop trailing empty line if present. */
        NSArray<NSString *> *allLines = [cigarsText componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *cigars = [NSMutableArray arrayWithCapacity:n];
        for (NSString *line in allLines) {
            if ([line length] > 0) [cigars addObject:line];
        }
        if ([cigars count] != n) {
            fprintf(stderr, "cigars line count mismatch: expected %lu, got %lu\n",
                (unsigned long)n, (unsigned long)[cigars count]);
            return 1;
        }

        NSError *err = nil;
        NSData *encoded = [TTIORefDiffV2 encodeSequences:sequences
                                                  offsets:offsets
                                                positions:positions
                                             cigarStrings:cigars
                                                reference:reference
                                             referenceMd5:referenceMd5
                                             referenceUri:referenceUri
                                           readsPerSlice:10000
                                                    error:&err];
        if (!encoded) {
            fprintf(stderr, "encode failed: %s\n",
                    [[err localizedDescription] UTF8String]);
            return 3;
        }

        NSString *outPath = @(argv[8]);
        if ([outPath isEqualToString:@"-"]) {
            fwrite([encoded bytes], 1, [encoded length], stdout);
            fflush(stdout);
        } else {
            if (![encoded writeToFile:outPath atomically:YES]) {
                fprintf(stderr, "failed to write %s\n", argv[8]);
                return 4;
            }
        }
        return 0;
    }
}
