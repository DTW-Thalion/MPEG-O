/*
 * TtioRefXLangReader — tio-browser Phase 0 Task 0.6 standalone CLI
 * helper that opens a .tio, reads -[TTIOSpectralDataset references],
 * and prints a single line of canonical JSON to stdout:
 *
 *     {"<uri>": {"_md5": "<hex>",
 *                "<chrom>": "<lowercase-hex-bytes>", ...}, ...}
 *
 * URIs and chromosome names are emitted in alphabetical order. The
 * "_md5" key (underscore-prefix sorts before any chromosome name)
 * carries the @md5 attribute round-tripped verbatim from disk so
 * cross-language byte parity on the MD5 attribute is exercised in
 * addition to the chromosome-content parity.
 *
 * Usage: TtioRefXLangReader <in.tio>
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOReferenceImport.h"
#include <stdio.h>

static NSString *xlangHexEncode(NSData *bytes)
{
    NSMutableString *hex =
        [NSMutableString stringWithCapacity:bytes.length * 2];
    const uint8_t *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        [hex appendFormat:@"%02x", p[i]];
    }
    return hex;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: TtioRefXLangReader <in.tio>\n");
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

        NSDictionary<NSString *, TTIOReferenceImport *> *refs = ds.references;
        NSArray<NSString *> *uris =
            [refs.allKeys sortedArrayUsingSelector:@selector(compare:)];

        NSMutableString *json = [NSMutableString stringWithString:@"{"];
        BOOL firstUri = YES;
        for (NSString *uri in uris) {
            if (!firstUri) [json appendString:@","];
            firstUri = NO;
            [json appendFormat:@"\"%@\":{", uri];
            TTIOReferenceImport *r = refs[uri];
            // _md5 first (sorts before any chromosome name).
            [json appendFormat:@"\"_md5\":\"%@\"", [r md5Hex]];
            NSArray<NSString *> *chroms =
                [r.chromosomes sortedArrayUsingSelector:@selector(compare:)];
            for (NSString *chrom in chroms) {
                [json appendString:@","];
                NSData *seq = [r chromosomeNamed:chrom];
                [json appendFormat:@"\"%@\":\"%@\"",
                                   chrom, xlangHexEncode(seq)];
            }
            [json appendString:@"}"];
        }
        [json appendString:@"}"];
        printf("%s\n", [json UTF8String]);

        [ds closeFile];
    }
    return 0;
}
