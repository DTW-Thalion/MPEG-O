/*
 * TtioSpectralReadBench.m
 * TTI-O Objective-C Implementation
 *
 * Reads every spectrum of an MS run two ways and reports MB/s: the
 * ordered reader -iterSpectraWithBatch:threads:, and the parallel block
 * consumer -iterBlocksFrom:to:threads:.
 *
 * usage: TtioSpectralReadBench <mode> <file.tio> <run> [threads]
 *        mode is "seq" or "par".
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import <Foundation/Foundation.h>
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "Providers/TTIOProviderRegistry.h"

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: %s <seq|par> <file.tio> <run> [threads]\n", argv[0]);
            return 2;
        }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        NSString *runName = [NSString stringWithUTF8String:argv[3]];
        NSUInteger threads = (argc > 4) ? (NSUInteger)atoi(argv[4]) : 1;

        NSError *err = nil;
        id<TTIOStorageProvider> prov = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead provider:nil error:&err];
        if (!prov) { fprintf(stderr, "open failed\n"); return 2; }
        id<TTIOStorageGroup> root = [prov rootGroupWithError:&err];
        id<TTIOStorageGroup> study = [root openGroupNamed:@"study" error:&err];
        id<TTIOStorageGroup> runs = [study openGroupNamed:@"ms_runs" error:&err];
        TTIOAcquisitionRun *run = [TTIOAcquisitionRun readFromGroup:runs
                                                              name:runName error:&err];
        if (!run) { fprintf(stderr, "run open failed: %s\n",
                            [[err localizedDescription] UTF8String] ?: ""); return 2; }

        NSUInteger n = [run count];
        unsigned long long values = 0;
        for (NSUInteger i = 0; i < n; i++) values += [run.spectrumIndex lengthAt:i];
        /* Two float64 channels are read per spectrum. */
        double mb = (double)values * 8.0 * 2.0 / 1e6;

        __block double checksum = 0;
        __block NSUInteger units = 0;
        NSLock *lock = [NSLock new];
        NSDate *t0 = [NSDate date];

        if ([mode isEqualToString:@"par"]) {
            [run iterBlocksFrom:0 to:n threads:threads error:&err
                     usingBlock:^(TTIOAcquisitionRun *view, NSUInteger viewStart,
                                  NSUInteger firstSpectrum, NSUInteger nSpectra,
                                  BOOL *stop) {
                double local = 0;
                for (NSUInteger k = 0; k < nSpectra; k++) {
                    TTIOMassSpectrum *sp = [view spectrumAtIndex:viewStart + k error:NULL];
                    /* Hold the returned buffer: ARC releases it at the end
                     * of the statement that produced it. */
                    NSData *buf = [sp.intensityArray float64Buffer];
                    const double *v = buf.bytes;
                    NSUInteger m = buf.length / sizeof(double);
                    for (NSUInteger j = 0; j < m; j++) local += v[j];
                }
                [lock lock]; checksum += local; units++; [lock unlock];
            }];
        } else {
            [run iterSpectraWithBatch:4096 threads:threads error:&err
                           usingBlock:^(id spectrum, NSUInteger index, BOOL *stop) {
                TTIOMassSpectrum *sp = (TTIOMassSpectrum *)spectrum;
                NSData *buf = [sp.intensityArray float64Buffer];
                const double *v = buf.bytes;
                NSUInteger m = buf.length / sizeof(double);
                for (NSUInteger j = 0; j < m; j++) checksum += v[j];
            }];
            units = 1;
        }

        double secs = -[t0 timeIntervalSinceNow];
        printf("%s threads=%lu spectra=%lu units=%lu MB=%.1f seconds=%.2f MB/s=%.1f "
               "checksum=%.6e\n",
               [mode UTF8String], (unsigned long)threads, (unsigned long)n,
               (unsigned long)units, mb, secs, mb / secs, checksum);
        [prov close];
    }
    return 0;
}
