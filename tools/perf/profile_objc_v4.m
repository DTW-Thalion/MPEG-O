// profile_objc_v4.m — V4 codec throughput on real or synthetic input.
//
// Runs a single encode + decode pass over the FQZCOMP_NX16_Z V4 path
// in libttio_rans, reporting MB/s and B/qual. Inputs come from one of:
//   - synthetic 100K reads × 100 bp Q20-Q40 LCG (default)
//   - a pre-extracted corpus from /tmp/{name}_v4_qual.bin etc.,
//     written by tools/perf/htscodecs_compare.sh
//
// Usage:
//   profile_objc_v4                   # synthetic 10 MiB
//   profile_objc_v4 chr22             # real chr22 (170 MiB qualities)
//   profile_objc_v4 wes               # NA12878 WES
//   profile_objc_v4 hg002_illumina    # HG002 Illumina
//   profile_objc_v4 hg002_pacbio      # HG002 PacBio HiFi
//
// Companion to:
//   tools/perf/profile_python_full.py --only codecs.genomic
//   tools/perf/ProfileHarnessFull.java --only codecs.genomic
//
// SPDX-License-Identifier: LGPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "Codecs/TTIOFqzcompNx16Z.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double monoSeconds(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static NSData *readFile(NSString *path) {
    return [NSData dataWithContentsOfFile:path];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSData *qualities = nil;
        NSMutableArray<NSNumber *> *lens = nil;
        NSMutableArray<NSNumber *> *rev  = nil;
        const char *label = "synth-10MiB";

        if (argc > 1) {
            // Corpus mode: read /tmp/{name}_v4_qual.bin etc.
            const char *corpus = argv[1];
            NSString *qpath = [NSString stringWithFormat:@"/tmp/%s_v4_qual.bin",  corpus];
            NSString *lpath = [NSString stringWithFormat:@"/tmp/%s_v4_lens.bin",  corpus];
            NSString *fpath = [NSString stringWithFormat:@"/tmp/%s_v4_flags.bin", corpus];
            qualities = readFile(qpath);
            NSData *lensBlob  = readFile(lpath);
            NSData *flagsBlob = readFile(fpath);
            if (!qualities || !lensBlob || !flagsBlob) {
                fprintf(stderr,
                    "ERROR: corpus '%s' inputs missing in /tmp.\n"
                    "Run: bash tools/perf/htscodecs_compare.sh\n",
                    corpus);
                return 1;
            }
            size_t nReads = lensBlob.length / 4;
            const uint32_t *lensArr  = (const uint32_t *)lensBlob.bytes;
            const uint32_t *flagsArr = (const uint32_t *)flagsBlob.bytes;
            lens = [NSMutableArray arrayWithCapacity:nReads];
            rev  = [NSMutableArray arrayWithCapacity:nReads];
            for (size_t i = 0; i < nReads; i++) {
                [lens addObject:@(lensArr[i])];
                [rev  addObject:@((flagsArr[i] & 16) != 0 ? 1 : 0)];
            }
            label = corpus;
        } else {
            // Synthetic 100K × 100 bp, matching profile_python_full
            // bench_codecs_genomic + ProfileHarnessFull.benchCodecsGenomic.
            const NSUInteger nReads = 100000;
            const NSUInteger readLen = 100;
            const NSUInteger nQual = nReads * readLen;
            NSMutableData *q = [NSMutableData dataWithLength:nQual];
            uint8_t *p = (uint8_t *)q.mutableBytes;
            uint64_t s = 0xBEEFULL;
            for (NSUInteger i = 0; i < nQual; i++) {
                s = s * 6364136223846793005ULL + 1442695040888963407ULL;
                p[i] = (uint8_t)(33u + 20u + (uint32_t)((s >> 32) % 21u));
            }
            qualities = q;
            lens = [NSMutableArray arrayWithCapacity:nReads];
            rev  = [NSMutableArray arrayWithCapacity:nReads];
            for (NSUInteger i = 0; i < nReads; i++) {
                [lens addObject:@(readLen)];
                [rev  addObject:@((i & 7) == 0 ? 1 : 0)];
            }
        }

        size_t nQual = qualities.length;
        size_t nReads = lens.count;
        double mib = (double)nQual / (1024.0 * 1024.0);
        fprintf(stderr,
            "ObjC V4 bench [%s]: backend=%s, %zu reads, %zu qualities (%.2f MiB)\n",
            label, [[TTIOFqzcompNx16Z backendName] UTF8String],
            nReads, (size_t)nQual, mib);

        // pad_count = (-num_qualities) & 3
        uint8_t padCount = (uint8_t)((-(NSInteger)nQual) & 0x3);

        // ── Encode ───────────────────────────────────────
        double t0 = monoSeconds();
        NSError *err = nil;
        NSData *enc = [TTIOFqzcompNx16Z encodeV4WithQualities:qualities
                                                  readLengths:lens
                                                 revcompFlags:rev
                                                 strategyHint:-1
                                                     padCount:padCount
                                                        error:&err];
        double tEnc = monoSeconds() - t0;
        if (!enc) {
            fprintf(stderr, "encode FAILED: %s\n",
                    err.localizedDescription.UTF8String);
            return 2;
        }
        int version = ((const uint8_t *)enc.bytes)[4];

        // ── Decode ───────────────────────────────────────
        t0 = monoSeconds();
        err = nil;
        NSDictionary *dec = [TTIOFqzcompNx16Z decodeData:enc revcompFlags:rev
                                                   error:&err];
        double tDec = monoSeconds() - t0;
        if (!dec) {
            fprintf(stderr, "decode FAILED: %s\n",
                    err.localizedDescription.UTF8String);
            return 3;
        }
        BOOL ok = [dec[@"qualities"] isEqualToData:qualities];

        // ── Report ───────────────────────────────────────
        fprintf(stderr,
            "ObjC V4 [%s]: V%d roundtrip=%s out=%lu bytes (B/qual=%.4f)\n"
            "  encode: %.3f s   %.2f MiB/s\n"
            "  decode: %.3f s   %.2f MiB/s\n",
            label, version, ok ? "OK" : "FAIL",
            (unsigned long)enc.length, (double)enc.length / (double)nQual,
            tEnc, mib / tEnc, tDec, mib / tDec);
        return ok ? 0 : 4;
    }
}
