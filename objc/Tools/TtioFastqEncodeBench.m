/*
 * TtioFastqEncodeBench — times a FASTQ import into a blocks_v1 .tio
 * through the streaming importer (the parallel producer when
 * TTIO_THREADS resolves above one), so the encode throughput the
 * parallel-producer work targets stays watched.
 *
 * Usage: TtioFastqEncodeBench <in.fastq[.gz]> <out.tio> [batchBytes]
 *
 * Emits one line:
 *   [obj-bench] FASTQ encode <in> B in <wall> s: <MB/s> MB/s, peak <MB> MB
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Import/TTIOFastqReader.h"
#import "Import/TTIOImportedDataset.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/resource.h>

static double benchNow(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1.0e9;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: TtioFastqEncodeBench <in.fastq[.gz]> <out.tio> [batchBytes]\n");
            return 1;
        }
        NSString *in = @(argv[1]), *out = @(argv[2]);
        unsigned long long batchBytes = argc > 3 ? strtoull(argv[3], NULL, 10) : 0;
        [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
        NSError *err = nil;
        TTIOImportedDataset *d = [[TTIOImportedDataset alloc] init];
        d.genomicStreams[@"genomic_0001"] =
            [TTIOFastqReader streamFromPath:in name:@"genomic_0001"
                                 sampleName:@"s" batchReads:0 batchBytes:batchBytes
                                   progress:nil];
        double t0 = benchNow();
        BOOL ok = [d writeToPath:out error:&err];
        double t1 = benchNow();
        if (!ok) {
            fprintf(stderr, "encode failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 2;
        }
        unsigned long long insz =
            [[[NSFileManager defaultManager] attributesOfItemAtPath:in error:NULL] fileSize];
        struct rusage ru;
        getrusage(RUSAGE_SELF, &ru);
        printf("[obj-bench] FASTQ encode %llu B in %.1f s: %.1f MB/s, peak %ld MB\n",
               insz, t1 - t0, (double)insz / (t1 - t0) / 1048576.0,
               ru.ru_maxrss / 1024);
        return 0;
    }
}
