/*
 * TtioGenomicWriteBench — times a blocks_v1 write through
 * TTIOGenomicStreamWriter, once per writer-thread count, so the pool
 * size can be tuned against the Objective-C writer rather than against
 * a synthetic C caller.
 *
 * TTIO_THREADS = cpu_count - 2 was fitted on native/tools/v6_acceptance.c,
 * which encodes qualities and nothing else. The writer's per-block work
 * is larger: it builds the chromosome map, plans and encodes every
 * channel, deflates the read-length table and appends to the storage
 * datasets, and part of that is serial in the caller's thread. A rule
 * fitted where the serial part is absent need not hold where it is not.
 *
 * Usage: TtioGenomicWriteBench <n_reads> <read_len> <block_reads>
 *                              [configs] [rounds]
 *        configs are W or W:T, comma separated, default
 *        1,2,4,8,16,24,30,32; rounds default 3. W is the writer pool
 *        size, T the V6 segment thread count (TTIO_V6_SEGMENT_THREADS;
 *        absent or 0 leaves the shipped rule). T reaches V6 only, and
 *        the writer takes V6 only under TTIO_M94Z_HINT=8.
 *        The run goes to a memory:// store, which keeps the disk off
 *        the clock and leaves the encode as what is measured.
 *
 * A control row repeats the first configuration under a second name.
 * When it disagrees with its twin by as much as the configurations
 * disagree with each other, the machine is too noisy to have measured
 * anything, and the tool says so instead of reporting the spread.
 *
 * Two things about that control, both learned the hard way here:
 * list a CONTENDED configuration first, because drift measured on a
 * one-writer row is small for reasons that say nothing about a row
 * running thirty; and the drift within one invocation understates the
 * drift between two, which on this machine reached 23% on identical
 * settings. A configuration is only distinguishable from another when
 * it stays ahead across several invocations, compared on their minima.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>

static double benchNow(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1.0e9;
}

/* A 64-bit LCG rather than arc4random: the corpus has to be the same
 * one every round, or the rows compare different data. */
static unsigned long long gSeed = 11;
static double nextUniform(void)
{
    gSeed = gSeed * 6364136223846793005ull + 1442695040888963407ull;
    return (double)((gSeed >> 11) & ((1ull << 53) - 1)) / (double)(1ull << 53);
}

/* Box-Muller, one of the pair kept. */
static double nextNormal(double sd)
{
    double u1 = nextUniform();
    double u2 = nextUniform();
    if (u1 < 1e-12) u1 = 1e-12;
    return sd * sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

/* The corpus of the Python read benchmark, in the same shape: quality
 * declines along the read, each read carries an offset of its own, and
 * a per-base term sits on top. Qualities worth compressing, so the
 * codec models something rather than a flat line. */
static TTIOWrittenGenomicRun *buildRun(NSUInteger nReads, NSUInteger readLen)
{
    unsigned long long total = (unsigned long long)nReads * readLen;
    NSMutableData *quals = [NSMutableData dataWithLength:total];
    NSMutableData *seqs = [NSMutableData dataWithLength:total];
    unsigned char *q = quals.mutableBytes, *s = seqs.mutableBytes;
    static const char bases[4] = { 'A', 'C', 'G', 'T' };

    for (NSUInteger i = 0; i < nReads; i++) {
        double perRead = nextNormal(2.5);
        unsigned char *qr = q + (size_t)i * readLen;
        unsigned char *sr = s + (size_t)i * readLen;
        for (NSUInteger j = 0; j < readLen; j++) {
            double ramp = 38.0 - 12.0 * ((double)j / (double)(readLen > 1 ? readLen - 1 : 1));
            double v = ramp + perRead + nextNormal(2.0);
            if (v < 2.0) v = 2.0;
            if (v > 41.0) v = 41.0;
            qr[j] = (unsigned char)v;
            sr[j] = (unsigned char)bases[(int)(nextUniform() * 4.0) & 3];
        }
    }

    NSMutableData *positions = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *mapq = [NSMutableData dataWithLength:nReads];
    NSMutableData *flags = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *offsets = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *matePos = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *tlen = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
    int64_t *pp = positions.mutableBytes, *mp = matePos.mutableBytes;
    uint8_t *mq = mapq.mutableBytes;
    uint32_t *fl = flags.mutableBytes, *ln = lengths.mutableBytes;
    uint64_t *of = offsets.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) {
        pp[i] = (int64_t)i * 10 + 1;
        mq[i] = 60;
        fl[i] = 0;
        of[i] = (uint64_t)i * readLen;
        ln[i] = (uint32_t)readLen;
        mp[i] = -1;
    }
    (void)tlen;

    NSString *cigar = [NSString stringWithFormat:@"%luM", (unsigned long)readLen];
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        [cigars addObject:cigar];
        [names addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [mateChroms addObject:@"*"];
        [chroms addObject:@"chr1"];
    }

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"synthetic.ref"
                       platform:@"ILLUMINA"
                     sampleName:@"bench"
                      positions:positions
               mappingQualities:mapq
                          flags:flags
                      sequences:seqs
                      qualities:quals
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlen
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
}

/* Total compressed bytes over every channel of every block: an
 * invariant that must not move with the thread count, because the file
 * is meant to be byte for byte the one thread's. */
static unsigned long long outputBytes(id<TTIOStorageGroup> study, NSString *name)
{
    NSError *err = nil;
    id<TTIOStorageGroup> runs = [study openGroupNamed:@"genomic_runs" error:&err];
    id<TTIOStorageGroup> rg = [runs openGroupNamed:name error:&err];
    id<TTIOStorageDataset> idx =
        [[rg openGroupNamed:@"blocks" error:&err] openDatasetNamed:@"index" error:&err];
    NSArray *rows = [idx readRows:&err];
    unsigned long long sum = 0;
    for (NSDictionary *row in rows) {
        for (NSString *key in row) {
            if ([key hasSuffix:@"_len"]) sum += [row[key] unsignedLongLongValue];
        }
    }
    return sum;
}

static BOOL onePass(TTIOWrittenGenomicRun *run, NSUInteger writers,
                    NSUInteger segThreads, NSUInteger blockReads,
                    double *secsOut, NSUInteger *blocksOut,
                    unsigned long long *bytesOut, NSUInteger *resolvedOut,
                    NSInteger *hintOut)
{
    @autoreleasepool {
        NSError *err = nil;
        /* The pool reads this when the writer opens it, so it has to be
         * set before the writer is constructed. 0 means the shipped
         * rule, clamp(cores / workers, 2, 8). */
        if (segThreads > 0) {
            char buf[32];
            snprintf(buf, sizeof buf, "%lu", (unsigned long)segThreads);
            setenv("TTIO_V6_SEGMENT_THREADS", buf, 1);
        } else {
            unsetenv("TTIO_V6_SEGMENT_THREADS");
        }
        NSString *url =
            [NSString stringWithFormat:@"memory://write-bench-%d", (int)getpid()];
        [TTIOMemoryProvider discardStore:url];
        id<TTIOStorageProvider> p = [[TTIOProviderRegistry sharedRegistry]
            openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory" error:&err];
        if (!p) {
            fprintf(stderr, "memory openURL failed: %s\n", err.description.UTF8String);
            return NO;
        }
        id<TTIOStorageGroup> study =
            [[p rootGroupWithError:&err] createGroupNamed:@"study" error:&err];
        if (!study) {
            fprintf(stderr, "no study group: %s\n", err.description.UTF8String);
            return NO;
        }

        TTIOGenomicStreamWriterOptions *o =
            [TTIOGenomicStreamWriterOptions optionsFromRun:run];
        o.blockReads = blockReads;
        o.threads = writers;

        double t0 = benchNow();
        TTIOGenomicStreamWriter *w =
            [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study
                                                        runName:@"g"
                                                        options:o];
        if (![w appendBatch:run error:&err] || ![w close:&err]) {
            fprintf(stderr, "write failed: %s\n", err.description.UTF8String);
            return NO;
        }
        double dt = benchNow() - t0;

        *secsOut = dt;
        *blocksOut = w.blockCount;
        *resolvedOut = w.threads;
        *hintOut = w.qualStrategyHint;
        *bytesOut = outputBytes(study, @"g");
        [TTIOMemoryProvider discardStore:url];
    }
    return YES;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: TtioGenomicWriteBench <n_reads> <read_len> "
                            "<block_reads> [configs] [rounds]\n"
                            "  configs are W or W:T, comma separated\n");
            return 1;
        }
        NSUInteger nReads = (NSUInteger)strtoull(argv[1], NULL, 10);
        NSUInteger readLen = (NSUInteger)strtoull(argv[2], NULL, 10);
        NSUInteger blockReads = (NSUInteger)strtoull(argv[3], NULL, 10);
        NSString *configArg = argc > 4 ? @(argv[4]) : @"1,2,4,8,16,24,30,32";
        int rounds = argc > 5 ? atoi(argv[5]) : 3;
        if (rounds < 1) rounds = 1;
        if (nReads < 1 || readLen < 1 || blockReads < 1) {
            fprintf(stderr, "n_reads, read_len and block_reads must be positive\n");
            return 1;
        }

        /* "W" or "W:T": T is the V6 segment thread count, 0 or absent
         * meaning the shipped rule. T only reaches V6, which the writer
         * takes only under TTIO_M94Z_HINT=8. */
        NSMutableArray<NSNumber *> *writers = [NSMutableArray array];
        NSMutableArray<NSNumber *> *segs = [NSMutableArray array];
        for (NSString *piece in [configArg componentsSeparatedByString:@","]) {
            NSArray<NSString *> *wt = [piece componentsSeparatedByString:@":"];
            NSInteger w = [wt[0] integerValue];
            NSInteger t = wt.count > 1 ? [wt[1] integerValue] : 0;
            if (w > 0) {
                [writers addObject:@(w)];
                [segs addObject:@(t > 0 ? t : 0)];
            }
        }
        if (writers.count == 0) {
            fprintf(stderr, "no usable configurations in \"%s\"\n", configArg.UTF8String);
            return 1;
        }

        double t0 = benchNow();
        TTIOWrittenGenomicRun *run = buildRun(nReads, readLen);
        double built = benchNow() - t0;
        unsigned long long qualBytes = (unsigned long long)nReads * readLen;

        printf("[obj-bench] corpus reads=%lu read_len=%lu qual_bytes=%llu "
               "block_reads=%lu built in %.1f s; cores=%d rounds=%d "
               "store=memory://\n",
               (unsigned long)nReads, (unsigned long)readLen, qualBytes,
               (unsigned long)blockReads, built,
               (int)[[NSProcessInfo processInfo] activeProcessorCount], rounds);
        fflush(stdout);

        NSMutableArray<NSNumber *> *plan = [writers mutableCopy];
        NSMutableArray<NSNumber *> *planSegs = [segs mutableCopy];
        [plan addObject:writers[0]];
        [planSegs addObject:segs[0]];
        NSUInteger controlIdx = plan.count - 1;
        if (plan.count > 64) return 1;

        double best[64];
        NSUInteger blocks[64], resolved[64];
        NSInteger hint[64];
        unsigned long long outBytes[64];
        for (NSUInteger k = 0; k < plan.count; k++) {
            best[k] = 0.0; blocks[k] = 0; resolved[k] = 0;
            hint[k] = -1; outBytes[k] = 0;
        }

        for (int r = 0; r < rounds; r++) {
            for (NSUInteger k = 0; k < plan.count; k++) {
                double secs = 0.0;
                NSUInteger nb = 0, res = 0;
                NSInteger h = -1;
                unsigned long long ob = 0;
                if (!onePass(run, [plan[k] unsignedIntegerValue],
                             [planSegs[k] unsignedIntegerValue], blockReads,
                             &secs, &nb, &ob, &res, &h)) {
                    return 1;
                }
                if (outBytes[k] != 0 && outBytes[k] != ob) {
                    fprintf(stderr, "output size moved between rounds at "
                                    "writers=%lu: %llu then %llu\n",
                            (unsigned long)[plan[k] unsignedIntegerValue],
                            outBytes[k], ob);
                    return 1;
                }
                if (best[k] == 0.0 || secs < best[k]) best[k] = secs;
                blocks[k] = nb; resolved[k] = res; outBytes[k] = ob; hint[k] = h;
            }
        }

        for (NSUInteger k = 0; k < plan.count; k++) {
            char label[48];
            NSUInteger t = [planSegs[k] unsignedIntegerValue];
            if (k == controlIdx) {
                snprintf(label, sizeof label, "control");
            } else if (t > 0) {
                snprintf(label, sizeof label, "%lu:%lu",
                         (unsigned long)[plan[k] unsignedIntegerValue],
                         (unsigned long)t);
            } else {
                snprintf(label, sizeof label, "%lu",
                         (unsigned long)[plan[k] unsignedIntegerValue]);
            }
            printf("[obj-bench] config=%-9s resolved=%-3lu blocks=%-3lu hint=%-3ld "
                   "%.2f s: %.1f MB/s qualities, out=%llu B\n",
                   label, (unsigned long)resolved[k], (unsigned long)blocks[k],
                   (long)hint[k], best[k],
                   (double)qualBytes / best[k] / 1048576.0, outBytes[k]);
        }

        /* Every row must produce the same file: the pool changes when
         * blocks encode, not what they encode. */
        BOOL identical = YES;
        for (NSUInteger k = 1; k < plan.count; k++) {
            if (outBytes[k] != outBytes[0]) identical = NO;
        }
        printf("[obj-bench] output size %s across configurations\n",
               identical ? "CONSTANT" : "MOVED - the rows are not comparable");

        struct rusage ru;
        getrusage(RUSAGE_SELF, &ru);
        printf("[obj-bench] peak rss for this run: %.0f MB (all rows; "
               "ru_maxrss never resets, so per-row residency needs one "
               "process per row)\n", (double)ru.ru_maxrss / 1024.0);

        double drift = fabs(best[controlIdx] / best[0] - 1.0) * 100.0;
        double slowest = 0.0, fastest = 0.0;
        for (NSUInteger k = 0; k < writers.count; k++) {
            if (fastest == 0.0 || best[k] < fastest) fastest = best[k];
            if (best[k] > slowest) slowest = best[k];
        }
        double spread = (slowest / fastest - 1.0) * 100.0;
        printf("[obj-bench] control drift=%.1f%% config spread=%.1f%%\n",
               drift, spread);
        printf("[obj-bench] verdict: the configuration %s\n",
               spread <= drift * 1.5
                   ? "does NOT bind - the spread across configurations is "
                     "within the drift between two runs of the same one"
                   : "BINDS - changing it moves the rate by more than the "
                     "machine's own drift");
    }
    return 0;
}
