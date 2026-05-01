// PerfHarness.m — standalone FQZCOMP_NX16_Z perf+profile entry point.
#import <Foundation/Foundation.h>
#import "Codecs/TTIOFqzcompNx16Z.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double monoSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static NSData *_buildVariedQualities(NSUInteger n)
{
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    uint64_t s = 0xBEEFULL;
    for (NSUInteger i = 0; i < n; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        p[i] = (uint8_t)(33u + 20u + (uint32_t)((s >> 32) % 21u));
    }
    return out;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSUInteger nReads = 10000;
        NSUInteger readLen = 100;
        if (argc > 1) nReads = (NSUInteger)atol(argv[1]);
        if (argc > 2) readLen = (NSUInteger)atol(argv[2]);
        NSUInteger nQual = nReads * readLen;
        NSData *qualities = _buildVariedQualities(nQual);
        NSMutableArray<NSNumber *> *readLengths = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray<NSNumber *> *revcompFlags = [NSMutableArray arrayWithCapacity:nReads];
        for (NSUInteger i = 0; i < nReads; i++) {
            [readLengths addObject:@(readLen)];
            [revcompFlags addObject:@((i & 7) == 0 ? 1 : 0)];
        }
        double t0 = monoSeconds();
        NSError *err = nil;
        NSData *encoded = [TTIOFqzcompNx16Z encodeWithQualities:qualities
                                                   readLengths:readLengths
                                                  revcompFlags:revcompFlags
                                                         error:&err];
        double tEnc = monoSeconds() - t0;
        if (encoded == nil) {
            fprintf(stderr, "encode FAILED: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        double mb = (double)nQual / 1e6;
        double encMBs = (tEnc > 0.0) ? (mb / tEnc) : 0.0;
        double ratio = (double)encoded.length / (double)nQual;
        fprintf(stderr,
                "PerfHarness: %lu reads x %lu bp = %.2f MB raw -> encode %.3f MB/s (%.3fs) ratio %.3fx out=%lu bytes\n",
                (unsigned long)nReads, (unsigned long)readLen, mb,
                encMBs, tEnc, ratio, (unsigned long)encoded.length);
    }
    return 0;
}
