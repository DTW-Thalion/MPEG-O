/*
 * TtioGenomicReadBench — times a full iteration of a blocks_v1 genomic
 * run, once per decode-ahead window, so the window can be tuned against
 * a compiled consumer rather than an interpreted one.
 *
 * The Python twin (ttio.tools.genomic_read_bench) found the shipped
 * window of four several times slower than two. That holds only for a
 * consumer as slow as CPython's: a decoder outrunning its consumer
 * twenty-five times over needs no lookahead, and the arithmetic changes
 * entirely if the consumer keeps up. This asks the same question where
 * the per-read work is compiled.
 *
 * Usage: TtioGenomicReadBench <file.tio> [run] [windows] [rounds]
 *        windows default 1,2,4,8,16; rounds default 3.
 *
 * A control row repeats the first window under a second name. When it
 * disagrees with its twin by as much as the windows disagree with each
 * other, the machine is too noisy to have measured anything, and the
 * tool says so instead of reporting the spread.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <sys/resource.h>

static double benchNow(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1.0e9;
}

static double peakRssMB(void)
{
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (double)ru.ru_maxrss / 1024.0;
}

/* One full pass. Every quality byte is touched, so the decode cannot be
 * skipped and the consumer cost is the real one. */
static BOOL onePass(NSString *path, NSString *runName, NSUInteger window,
                    double *secsOut, unsigned long long *readsOut,
                    unsigned long long *qualOut)
{
    char buf[32];
    snprintf(buf, sizeof buf, "%lu", (unsigned long)window);
    setenv("TTIO_READ_AHEAD_BLOCKS", buf, 1);

    BOOL ok = NO;
    @autoreleasepool {
        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (ds == nil) {
            fprintf(stderr, "readFromFilePath failed: %s\n",
                    err.description.UTF8String);
            return NO;
        }
        TTIOGenomicRun *g = ds.genomicRuns[runName];
        if (g == nil) {
            fprintf(stderr, "no genomic run named %s\n", runName.UTF8String);
            return NO;
        }
        __block unsigned long long n = 0, nq = 0;
        double t0 = benchNow();
        ok = [g iterReadsFrom:0 to:[g readCount] threads:0 error:&err
                   usingBlock:^(TTIOAlignedRead *r, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop;
            nq += (unsigned long long)r.qualities.length;
            n++;
        }];
        double dt = benchNow() - t0;
        [g close];
        if (!ok) {
            fprintf(stderr, "iteration failed: %s\n", err.description.UTF8String);
            return NO;
        }
        *secsOut = dt;
        *readsOut = n;
        *qualOut = nq;
    }
    return ok;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: TtioGenomicReadBench <file.tio> [run] "
                            "[windows] [rounds]\n");
            return 1;
        }
        NSString *path = @(argv[1]);
        NSString *runName = (argc > 2 && argv[2][0]) ? @(argv[2]) : nil;
        NSString *windowArg = argc > 3 ? @(argv[3]) : @"1,2,4,8,16";
        int rounds = argc > 4 ? atoi(argv[4]) : 3;
        if (rounds < 1) rounds = 1;

        /* par mode: the same full pass, every quality byte
         * touched, but the reads built and consumed on the pool. */
        if (argc > 5 && (strcmp(argv[5], "par") == 0
                         || strcmp(argv[5], "pardecode") == 0)) {
            BOOL decodeOnly = strcmp(argv[5], "pardecode") == 0;
            NSUInteger th = argc > 6 ? (NSUInteger)atoi(argv[6]) : 0;
            double bestT = 0;
            for (int r = 0; r < rounds; r++) {
                @autoreleasepool {
                    NSError *err = nil;
                    TTIOSpectralDataset *ds =
                        [TTIOSpectralDataset readFromFilePath:path error:&err];
                    NSString *nm = runName ?: [[ds.genomicRuns.allKeys
                        sortedArrayUsingSelector:@selector(compare:)] firstObject];
                    TTIOGenomicRun *g = ds.genomicRuns[nm];
                    __block int64_t n = 0, nq = 0;
                    double t0 = benchNow();
                    BOOL ok = [g iterBlocksFrom:0 to:[g readCount] threads:th error:&err
                                     usingBlock:^(TTIOGenomicRun *v, NSUInteger f0,
                                                  NSUInteger nr, BOOL *st) {
                        (void)f0; (void)st;
                        int64_t ln = 0, lq = 0;
                        @autoreleasepool {
                            if (decodeOnly) {
                                /* The block's qualities as one buffer:
                                 * the same decode, none of the per-read
                                 * objects. */
                                NSData *q = [v wholeQualitiesData];
                                const uint8_t *p = q.bytes;
                                int64_t s = 0;
                                for (NSUInteger k = 0; k < q.length; k++) s += p[k];
                                lq = (int64_t)q.length;
                                ln = (int64_t)nr;
                                if (s == -1) fprintf(stderr, " ");
                            } else {
                                for (NSUInteger k = 0; k < nr; k++) {
                                    NSError *e = nil;
                                    TTIOAlignedRead *rd = [v readAtIndex:k error:&e];
                                    if (!rd) break;
                                    lq += (int64_t)rd.qualities.length;
                                    ln++;
                                }
                            }
                        }
                        __sync_fetch_and_add(&n, ln);
                        __sync_fetch_and_add(&nq, lq);
                    }];
                    double dt = benchNow() - t0;
                    if (!ok) { fprintf(stderr, "parallel pass failed\n"); return 1; }
                    if (bestT == 0 || dt < bestT) bestT = dt;
                    printf("[obj-bench] par threads=%lu reads=%lld %.2f s: "
                           "%.0f reads/s, %.1f MB/s qualities\n",
                           (unsigned long)th, (long long)n, dt,
                           (double)n / dt, (double)nq / dt / 1.0e6);
                    [g close];
                }
            }
            printf("[obj-bench] par best %.2f s\n", bestT);
            return 0;
        }

        NSUInteger blocks = 0, reads = 0;
        @autoreleasepool {
            NSError *err = nil;
            TTIOSpectralDataset *ds =
                [TTIOSpectralDataset readFromFilePath:path error:&err];
            if (ds == nil) {
                fprintf(stderr, "readFromFilePath failed: %s\n",
                        err.description.UTF8String);
                return 1;
            }
            NSArray<NSString *> *names =
                [ds.genomicRuns.allKeys sortedArrayUsingSelector:@selector(compare:)];
            if (names.count == 0) {
                fprintf(stderr, "%s holds no genomic runs\n", path.UTF8String);
                return 1;
            }
            if (runName == nil) runName = names.firstObject;
            TTIOGenomicRun *probe = ds.genomicRuns[runName];
            if (probe == nil) {
                fprintf(stderr, "no genomic run named %s\n", runName.UTF8String);
                return 1;
            }
            blocks = [probe blockCount];
            reads = [probe readCount];
            [probe close];
        }

        NSMutableArray<NSNumber *> *windows = [NSMutableArray array];
        for (NSString *piece in [windowArg componentsSeparatedByString:@","]) {
            NSInteger w = [piece integerValue];
            if (w > 0) [windows addObject:@(w)];
        }
        if (windows.count == 0) {
            fprintf(stderr, "no usable windows in \"%s\"\n", windowArg.UTF8String);
            return 1;
        }

        printf("[obj-bench] file=%s run=%s blocks=%lu reads=%lu rounds=%d\n",
               path.lastPathComponent.UTF8String, runName.UTF8String,
               (unsigned long)blocks, (unsigned long)reads, rounds);
        fflush(stdout);

        NSMutableArray<NSNumber *> *plan = [windows mutableCopy];
        [plan addObject:windows[0]];
        NSUInteger controlIdx = plan.count - 1;
        if (plan.count > 64) return 1;

        double best[64];
        unsigned long long bestReads[64], bestQual[64];
        for (NSUInteger k = 0; k < plan.count; k++) {
            best[k] = 0.0;
            bestReads[k] = 0;
            bestQual[k] = 0;
        }

        for (int r = 0; r < rounds; r++) {
            for (NSUInteger k = 0; k < plan.count; k++) {
                double secs = 0.0;
                unsigned long long n = 0, nq = 0;
                if (!onePass(path, runName, [plan[k] unsignedIntegerValue],
                             &secs, &n, &nq)) {
                    return 1;
                }
                if (best[k] == 0.0 || secs < best[k]) {
                    best[k] = secs;
                    bestReads[k] = n;
                    bestQual[k] = nq;
                }
            }
        }

        for (NSUInteger k = 0; k < plan.count; k++) {
            char label[32];
            if (k == controlIdx) {
                snprintf(label, sizeof label, "control");
            } else {
                snprintf(label, sizeof label, "%lu",
                         (unsigned long)[plan[k] unsignedIntegerValue]);
            }
            printf("[obj-bench] window=%-8s reads=%llu %.2f s: %.0f reads/s, "
                   "%.1f MB/s qualities\n",
                   label, bestReads[k], best[k],
                   (double)bestReads[k] / best[k],
                   (double)bestQual[k] / best[k] / 1.0e6);
        }

        /* One number for the whole run: ru_maxrss is a process
         * high-water mark and never resets, so a per-window column
         * would report the largest window run so far rather than the
         * one on the line. Per-window residency needs one process per
         * window. */
        printf("[obj-bench] peak rss for this run: %.0f MB (all windows)\n",
               peakRssMB());

        double drift = fabs(best[controlIdx] / best[0] - 1.0) * 100.0;
        double slowest = 0.0, fastest = 0.0;
        for (NSUInteger k = 0; k < windows.count; k++) {
            if (fastest == 0.0 || best[k] < fastest) fastest = best[k];
            if (best[k] > slowest) slowest = best[k];
        }
        double spread = (slowest / fastest - 1.0) * 100.0;
        printf("[obj-bench] control drift=%.1f%% window spread=%.1f%%\n",
               drift, spread);
        printf("[obj-bench] verdict: the window %s\n",
               spread <= drift * 1.5
                   ? "does NOT bind - the spread across windows is within "
                     "the drift between two runs of the same window"
                   : "BINDS - widening it changes the rate by more than the "
                     "machine's own drift");
    }
    return 0;
}
