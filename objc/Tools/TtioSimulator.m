/*
 * TtioSimulator — v0.10 M69 command-line tool.
 *
 * Usage:
 *   TtioSimulator <output.tis> [--scan-rate N] [--duration N]
 *                 [--ms1-fraction N] [--mz-min N] [--mz-max N]
 *                 [--n-peaks N] [--seed N]
 *
 * Generates a synthetic TTI-O transport stream. Parallel to Python
 * ``python -m ttio.tools.simulator_cli`` and Java
 * ``global.thalion.ttio.tools.SimulatorCli``.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOAcquisitionSimulator.h"
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: TtioSimulator <output.tis> "
                            "[--scan-rate N] [--duration N] "
                            "[--ms1-fraction N] [--mz-min N] [--mz-max N] "
                            "[--n-peaks N] [--seed N]\n");
            return 2;
        }
        NSString *output = [NSString stringWithUTF8String:argv[1]];
        double scanRate = 10.0, duration = 10.0, ms1 = 0.3;
        double mzMin = 100.0, mzMax = 2000.0;
        NSUInteger nPeaks = 200;
        uint64_t seed = 42;
        for (int i = 2; i + 1 < argc; i += 2) {
            const char *key = argv[i];
            const char *val = argv[i + 1];
            if (strcmp(key, "--scan-rate") == 0) scanRate = atof(val);
            else if (strcmp(key, "--duration") == 0) duration = atof(val);
            else if (strcmp(key, "--ms1-fraction") == 0) ms1 = atof(val);
            else if (strcmp(key, "--mz-min") == 0) mzMin = atof(val);
            else if (strcmp(key, "--mz-max") == 0) mzMax = atof(val);
            else if (strcmp(key, "--n-peaks") == 0) nPeaks = (NSUInteger)atoi(val);
            else if (strcmp(key, "--seed") == 0) seed = (uint64_t)atoll(val);
            else {
                fprintf(stderr, "unknown flag: %s\n", key);
                return 2;
            }
        }

        TTIOAcquisitionSimulator *sim =
            [[TTIOAcquisitionSimulator alloc]
                initWithScanRate:scanRate duration:duration ms1Fraction:ms1
                           mzMin:mzMin mzMax:mzMax nPeaks:nPeaks seed:seed];
        TTIOTransportWriter *tw =
            [[TTIOTransportWriter alloc] initWithOutputPath:output];
        NSError *err = nil;
        NSUInteger n = [sim streamToWriter:tw error:&err];
        [tw close];
        if (n == 0) {
            fprintf(stderr, "simulator failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        printf("%lu access units written to %s\n",
               (unsigned long)n, output.UTF8String);
    }
    return 0;
}
