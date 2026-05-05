/*
 * TtioFastaRoundTrip — ObjC mirror of the Python and Java FASTA
 * round-trip CLIs for the cross-language FASTA conformance harness.
 *
 * Reads a FASTA file via TTIOFastaReader, then writes it back via
 * TTIOFastaWriter. Output is the canonical FASTA the conformance
 * harness diffs against the Python and Java outputs.
 *
 * Usage: TtioFastaRoundTrip <in.fa> <out.fa> [line_width]
 *
 * Exit codes: 0 = success, 1 = argument error, 2 = read/write
 * failure.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Genomics/TTIOReferenceImport.h"
#import "Import/TTIOFastaReader.h"
#import "Export/TTIOFastaWriter.h"


int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3 || argc > 4) {
            fprintf(stderr,
                    "usage: TtioFastaRoundTrip <in.fa> <out.fa> "
                    "[line_width]\n");
            return 1;
        }
        NSString *in = [NSString stringWithUTF8String:argv[1]];
        NSString *out = [NSString stringWithUTF8String:argv[2]];
        NSUInteger lineWidth = TTIOFastaWriterDefaultLineWidth;
        if (argc == 4) {
            lineWidth = (NSUInteger)atoi(argv[3]);
        }
        NSError *err = nil;
        TTIOReferenceImport *ref =
            [TTIOFastaReader readReferenceFromPath:in uri:nil error:&err];
        if (ref == nil) {
            fprintf(stderr, "error: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 2;
        }
        BOOL ok = [TTIOFastaWriter writeReference:ref
                                           toPath:out
                                        lineWidth:lineWidth
                                       gzipOutput:0
                                         writeFai:YES
                                            error:&err];
        if (!ok) {
            fprintf(stderr, "error: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 2;
        }
    }
    return 0;
}
