// TtioNameTokV2Cli — CLI for NAME_TOKENIZED v2 cross-language byte-equality tests.
//
// Reads ASCII read names (one per line) from arg[1], encodes via
// TTIONameTokenizerV2, writes the encoded blob to arg[2].
//
// Mirrors Java NameTokenizedV2Cli (T8) and the Python
// `python -m ttio.tools.name_tok_v2_cli` entry. All three CLIs share the same
// line-delimited input format so the Task 11 cross-lang gate can compare
// outputs byte-for-byte.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Codecs/TTIONameTokenizerV2.h"

#import <stdio.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s <names.txt> <out.bin>\n", argv[0]);
            return 1;
        }
        NSError *err = nil;
        NSString *txt = [NSString stringWithContentsOfFile:@(argv[1])
                                                  encoding:NSUTF8StringEncoding
                                                     error:&err];
        if (!txt) {
            fprintf(stderr, "read fail: %s\n",
                    [[err localizedDescription] UTF8String]);
            return 1;
        }
        NSArray<NSString *> *raw = [txt componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        for (NSString *s in raw) if ([s length] > 0) [clean addObject:s];

        NSData *blob = [TTIONameTokenizerV2 encodeNames:clean];
        if (![blob writeToFile:@(argv[2]) atomically:YES]) {
            fprintf(stderr, "write fail: %s\n", argv[2]);
            return 2;
        }
        fprintf(stdout, "encoded %lu names -> %lu bytes\n",
                (unsigned long)[clean count], (unsigned long)[blob length]);
    }
    return 0;
}
