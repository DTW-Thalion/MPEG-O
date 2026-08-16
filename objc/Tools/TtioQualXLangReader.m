/*
 * TtioQualXLangReader — qualities V5 cross-language reader helper.
 * Opens a .tio, takes the first genomic run (alphabetical), decodes
 * the qualities of its first 3 reads through the codec-12 dispatch
 * (V4 or V5), and prints one JSON line:
 *
 *     {"read_count": N, "qualities_hex": "..."}
 *
 * Usage: TtioQualXLangReader <in.tio>
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#include <stdio.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: TtioQualXLangReader <in.tio>\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (ds == nil) {
            fprintf(stderr, "readFromFilePath failed: %s\n",
                    [[err description] UTF8String]);
            return 1;
        }
        NSArray<NSString *> *names = [ds.genomicRuns.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        if (names.count == 0) {
            fprintf(stderr, "no genomic runs\n");
            return 1;
        }
        TTIOGenomicRun *gr = ds.genomicRuns[names.firstObject];
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger i = 0; i < 3; i++) {
            TTIOAlignedRead *rd = [gr readAtIndex:i error:&err];
            if (rd == nil) {
                fprintf(stderr, "readAtIndex:%lu failed: %s\n",
                        (unsigned long)i, [[err description] UTF8String]);
                return 1;
            }
            const uint8_t *p = rd.qualities.bytes;
            for (NSUInteger k = 0; k < rd.qualities.length; k++) {
                [hex appendFormat:@"%02x", p[k]];
            }
        }
        printf("{\"read_count\":%lu,\"qualities_hex\":\"%s\"}\n",
               (unsigned long)gr.count, [hex UTF8String]);
        return 0;
    }
}
