/*
 * TtioFastqBench — ObjC mirror of FastqBulkBenchTest (Java) for the
 * read-side TTIOFastqWriter bulk-fetch path.
 *
 * Synthesises N reads × 100 bp, writes a .fq, parses to
 * TTIOWrittenGenomicRun, persists to a .tio, reopens it, and times
 * +writeReadSideRun: against the resulting TTIOGenomicRun. Mirrors
 * commit ae9441d (Python 24×) + 0f99852 (Java + ObjC bulk-fetch).
 *
 * Usage: TtioFastqBench [N]
 *   N = number of reads (default 100000)
 *
 * Emits one [obj-bench] line on stdout:
 *   [obj-bench] FASTQ <N> reads × 100bp via GenomicRun bulk-fetch:
 *               <ms> ms (<rps> K reads/s)
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Import/TTIOFastqReader.h"
#import "Export/TTIOFastqWriter.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>  // getpid() for unique tmp paths


static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1.0e9;
}

static void synth_fastq(NSString *outPath, NSUInteger n, NSUInteger len)
{
    static const char bases[4] = {'A', 'C', 'G', 'T'};
    NSMutableData *buf = [NSMutableData dataWithCapacity:n * (len * 2 + 16)];
    unsigned int seed = 42;
    char hdr[64];
    for (NSUInteger i = 0; i < n; i++) {
        int hl = snprintf(hdr, sizeof(hdr), "@read_%lu\n", (unsigned long)i);
        [buf appendBytes:hdr length:(NSUInteger)hl];
        for (NSUInteger j = 0; j < len; j++) {
            char c = bases[rand_r(&seed) & 3];
            [buf appendBytes:&c length:1];
        }
        [buf appendBytes:"\n+\n" length:3];
        for (NSUInteger j = 0; j < len; j++) {
            char q = (char)('!' + (rand_r(&seed) % 40));
            [buf appendBytes:&q length:1];
        }
        [buf appendBytes:"\n" length:1];
    }
    [buf writeToFile:outPath atomically:YES];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSUInteger n = 100000;
        if (argc >= 2) n = (NSUInteger)atol(argv[1]);
        NSUInteger len = 100;

        NSString *tmp = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"ttio_fqbench_%d", (int)getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *src = [tmp stringByAppendingPathComponent:@"src.fq"];
        NSString *tio = [tmp stringByAppendingPathComponent:@"bench.tio"];
        NSString *out = [tmp stringByAppendingPathComponent:@"out.fq"];

        synth_fastq(src, n, len);

        NSError *err = nil;
        uint8_t detected = 0;
        TTIOWrittenGenomicRun *runIn =
            [TTIOFastqReader readFromPath:src
                              forcedPhred:0
                               sampleName:@"S1"
                                 platform:@""
                             referenceUri:@""
                          acquisitionMode:TTIOAcquisitionModeGenomicWGS
                              outDetected:&detected
                                    error:&err];
        if (!runIn) {
            fprintf(stderr, "FastqReader failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(nil)");
            return 2;
        }

        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:tio
                                                    title:@""
                                       isaInvestigationId:@""
                                                   msRuns:@{}
                                              genomicRuns:@{@"genomic_0001": runIn}
                                          identifications:nil
                                          quantifications:nil
                                        provenanceRecords:nil
                                                    error:&err];
        if (!ok) {
            fprintf(stderr, "tio write failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(nil)");
            return 2;
        }

        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:tio error:&err];
        if (!ds) {
            fprintf(stderr, "tio open failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(nil)");
            return 2;
        }
        TTIOGenomicRun *run = ds.genomicRuns[@"genomic_0001"];
        if (!run) {
            fprintf(stderr, "no genomic_0001 in %s\n", tio.UTF8String);
            return 2;
        }

        // Warm: pre-decode read names so the per-record loop is what we time.
        (void)[run allReadNames];

        double t0 = monotonic_seconds();
        ok = [TTIOFastqWriter writeReadSideRun:run
                                        toPath:out
                                    gzipOutput:0
                                   phredOffset:33
                                         error:&err];
        double t1 = monotonic_seconds();
        if (!ok) {
            fprintf(stderr, "fastq write failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(nil)");
            return 2;
        }
        double ms = (t1 - t0) * 1000.0;
        printf("[obj-bench] FASTQ %lu reads × %lubp via GenomicRun bulk-fetch: "
               "%.1f ms (%.0f K reads/s)\n",
               (unsigned long)n, (unsigned long)len, ms, (double)n / ms);

        // Best-effort cleanup.
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    }
    return 0;
}
