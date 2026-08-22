/*
 * TtioBamParseBench — the read-and-parse half of a BAM import, timed on
 * its own.
 *
 * A BAM import is samtools decoding BGZF and writing SAM text, this
 * process cutting and parsing that text into batches, and the genomic
 * writer encoding the batches into blocks. Only the middle stage is
 * this file's code, and only the sum of the three is visible from
 * TtioEncode. This runs the first two and discards every batch, so the
 * writer's share is the difference between the two tools on one file.
 *
 * Usage:
 *   TtioBamParseBench <in.bam> [batchReads]
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Import/TTIOBamReader.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#include <stdio.h>
#include <sys/time.h>

static double bpNow(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <in.bam> [batchReads]\n", argv[0]);
            return 2;
        }
        NSString *path = @(argv[1]);
        NSUInteger batchReads = argc > 2 ? (NSUInteger)atoll(argv[2]) : 100000;

        TTIOBamReader *reader = [[TTIOBamReader alloc] initWithPath:path];
        __block unsigned long long reads = 0, seqBytes = 0, batches = 0;
        NSError *err = nil;
        double t0 = bpNow();
        BOOL ok = [reader iterBatchesWithRegion:nil
                                     sampleName:nil
                                     batchReads:batchReads
                                       progress:nil
                                          error:&err
                                     usingBlock:^BOOL(TTIOWrittenGenomicRun *batch,
                                                      NSError **e) {
            (void)e;
            batches++;
            reads += batch.readCount;
            seqBytes += batch.sequencesData.length;
            return YES;   /* discard: the writer is what this excludes */
        }];
        double dt = bpNow() - t0;
        if (!ok) {
            fprintf(stderr, "parse failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 2;
        }
        unsigned long long inBytes =
            (unsigned long long)[[[NSFileManager defaultManager]
                attributesOfItemAtPath:path error:NULL] fileSize];
        printf("[obj-bench] BAM parse %llu reads in %llu batches, %.2f s: "
               "%.1f MB/s of BAM, %.0f k reads/s, %llu sequence bytes\n",
               reads, batches, dt,
               inBytes / 1048576.0 / dt,
               reads / 1000.0 / dt,
               seqBytes);
        return 0;
    }
}
