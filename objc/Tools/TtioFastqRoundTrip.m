/*
 * TtioFastqRoundTrip — ObjC mirror of the Python and Java FASTQ
 * round-trip CLIs for the cross-language FASTQ conformance harness.
 *
 * Reads a FASTQ file via TTIOFastqReader (auto-detect Phred), then
 * writes it back via TTIOFastqWriter. Phred+33 is the canonical
 * output offset.
 *
 * Usage: TtioFastqRoundTrip <in.fq> <out.fq>
 *
 * Exit codes: 0 = success, 1 = argument error, 2 = read/write
 * failure.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Import/TTIOFastqReader.h"
#import "Export/TTIOFastqWriter.h"


int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: TtioFastqRoundTrip <in.fq> <out.fq>\n");
            return 1;
        }
        NSString *in = [NSString stringWithUTF8String:argv[1]];
        NSString *out = [NSString stringWithUTF8String:argv[2]];
        NSError *err = nil;
        uint8_t detected = 0;
        TTIOWrittenGenomicRun *run =
            [TTIOFastqReader readFromPath:in
                              forcedPhred:0
                               sampleName:@""
                                 platform:@""
                             referenceUri:@""
                          acquisitionMode:TTIOAcquisitionModeGenomicWGS
                              outDetected:&detected
                                    error:&err];
        if (run == nil) {
            fprintf(stderr, "error: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 2;
        }
        BOOL ok = [TTIOFastqWriter writeRun:run
                                     toPath:out
                                 gzipOutput:0
                                phredOffset:33
                                      error:&err];
        if (!ok) {
            fprintf(stderr, "error: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 2;
        }
    }
    return 0;
}
