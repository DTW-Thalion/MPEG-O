/*
 * TestTask30MSProviderURL.m — Task 30 MS-runs via provider URL.
 *
 * Exercises +[TTIOSpectralDataset writeMinimalToPath:...] for non-HDF5
 * URLs (memory:// / sqlite:// / zarr://). Pre-Task-30 these returned
 * NSError code 1000 ("genomic_runs only"); Task 30 wires MS runs
 * through the StorageGroup protocol so the same call now works for
 * every registered backend.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "ValueClasses/TTIOEnums.h"
#import "Providers/TTIOMemoryProvider.h"
#include <unistd.h>

static TTIOWrittenRun *t30BuildRun(NSUInteger n)
{
    NSUInteger peaks = 4;
    NSUInteger total = n * peaks;
    NSMutableData *mzBuf  = [NSMutableData dataWithLength:total * sizeof(double)];
    NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
    double *mz  = (double *)mzBuf.mutableBytes;
    double *inn = (double *)intBuf.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        for (NSUInteger j = 0; j < peaks; j++) {
            NSUInteger pos = i * peaks + j;
            mz[pos]  = 100.0 + (double)i + (double)j * 0.1;
            inn[pos] = 1000.0 + (double)((i * 13 + j) % 1000);
        }
    }
    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *rts     = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *mls     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pols    = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pmzs    = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *pcs     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *bps     = [NSMutableData dataWithLength:n * sizeof(double)];
    int64_t  *op = (int64_t  *)offsets.mutableBytes;
    uint32_t *lp = (uint32_t *)lengths.mutableBytes;
    double   *rp = (double   *)rts.mutableBytes;
    int32_t  *mp = (int32_t  *)mls.mutableBytes;
    int32_t  *pp = (int32_t  *)pols.mutableBytes;
    double   *qp = (double   *)pmzs.mutableBytes;
    int32_t  *cp = (int32_t  *)pcs.mutableBytes;
    double   *bp = (double   *)bps.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        op[i] = (int64_t)(i * peaks);
        lp[i] = (uint32_t)peaks;
        rp[i] = (double)i * 0.06;
        mp[i] = 1; pp[i] = 1; qp[i] = 0.0; cp[i] = 0; bp[i] = 1000.0;
    }
    return [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz": mzBuf, @"intensity": intBuf}
                          offsets:offsets
                          lengths:lengths
                   retentionTimes:rts
                         msLevels:mls
                       polarities:pols
                     precursorMzs:pmzs
                 precursorCharges:pcs
              basePeakIntensities:bps];
}

static BOOL t30RoundTrip(NSString *url, NSUInteger nSpectra)
{
    @autoreleasepool {
        TTIOWrittenRun *run = t30BuildRun(nSpectra);
        NSError *err = nil;
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:url
                                                     title:@"task30"
                                       isaInvestigationId:@"ISA-T30"
                                                   msRuns:@{@"r": run}
                                           identifications:nil
                                           quantifications:nil
                                         provenanceRecords:nil
                                                     error:&err];
        if (!ok) {
            NSLog(@"Task30: writeMinimal to %@ failed: %@", url, err);
            return NO;
        }

        TTIOSpectralDataset *back = [TTIOSpectralDataset readFromFilePath:url error:&err];
        if (!back) {
            NSLog(@"Task30: readback of %@ failed: %@", url, err);
            return NO;
        }

        if (![back.title isEqualToString:@"task30"]) {
            NSLog(@"Task30 %@: title mismatch '%@'", url, back.title);
            return NO;
        }
        TTIOAcquisitionRun *r = back.msRuns[@"r"];
        if (!r) {
            NSLog(@"Task30 %@: msRuns[r] missing", url);
            return NO;
        }
        if (r.acquisitionMode != TTIOAcquisitionModeMS1DDA) {
            NSLog(@"Task30 %@: acquisitionMode mismatch %lld",
                  url, (long long)r.acquisitionMode);
            return NO;
        }
        if (![r.spectrumClassName isEqualToString:@"TTIOMassSpectrum"]) {
            NSLog(@"Task30 %@: spectrumClassName mismatch '%@'",
                  url, r.spectrumClassName);
            return NO;
        }
        if (r.spectrumIndex.count != nSpectra) {
            NSLog(@"Task30 %@: spectrum_index.count = %lu (expected %lu)",
                  url, (unsigned long)r.spectrumIndex.count,
                  (unsigned long)nSpectra);
            return NO;
        }
        // Verify a per-spectrum index entry survives the round-trip
        // (offset = i * peaks, length = peaks, ms_level = 1).
        for (NSUInteger i = 0; i < nSpectra; i++) {
            uint64_t off = [r.spectrumIndex offsetAt:i];
            uint32_t len = [r.spectrumIndex lengthAt:i];
            uint8_t  ml  = [r.spectrumIndex msLevelAt:i];
            if (off != (uint64_t)(i * 4) || len != 4 || ml != 1) {
                NSLog(@"Task30 %@: index[%lu] mismatch off=%llu len=%u ml=%u",
                      url, (unsigned long)i, (unsigned long long)off,
                      (unsigned)len, (unsigned)ml);
                return NO;
            }
        }
    }
    return YES;
}

void testTask30MSProviderURL(void)
{
    @autoreleasepool {
        // ── memory:// — write + read round-trip for MS runs ──────────
        NSString *memUrl = [NSString stringWithFormat:@"memory://t30-ms-%d", (int)getpid()];
        [TTIOMemoryProvider discardStore:memUrl];
        BOOL memOk = t30RoundTrip(memUrl, 8);
        PASS(memOk, "Task30 #1: memory:// MS-run writeMinimal+readback round-trip");
        [TTIOMemoryProvider discardStore:memUrl];

        // ── sqlite:// — write + read round-trip for MS runs ──────────
        NSString *sqlPath = [NSString stringWithFormat:@"/tmp/ttio_t30_ms_%d.sqlite",
                             (int)getpid()];
        unlink([sqlPath fileSystemRepresentation]);
        NSString *sqlUrl = [@"sqlite://" stringByAppendingString:sqlPath];
        BOOL sqlOk = t30RoundTrip(sqlUrl, 8);
        PASS(sqlOk, "Task30 #2: sqlite:// MS-run writeMinimal+readback round-trip");
        unlink([sqlPath fileSystemRepresentation]);

        // ── zarr:// — write + read round-trip for MS runs ────────────
        NSString *zPath = [NSString stringWithFormat:@"/tmp/ttio_t30_ms_%d.zarr",
                           (int)getpid()];
        [[NSFileManager defaultManager] removeItemAtPath:zPath error:NULL];
        NSString *zUrl = [@"zarr://" stringByAppendingString:zPath];
        BOOL zOk = t30RoundTrip(zUrl, 8);
        PASS(zOk, "Task30 #3: zarr:// MS-run writeMinimal+readback round-trip");
        [[NSFileManager defaultManager] removeItemAtPath:zPath error:NULL];

        // ── HDF5 plain path still works (regression guard) ───────────
        NSString *hPath = [NSString stringWithFormat:@"/tmp/ttio_t30_ms_%d.tio",
                           (int)getpid()];
        unlink([hPath fileSystemRepresentation]);
        BOOL hOk = t30RoundTrip(hPath, 8);
        PASS(hOk, "Task30 #4: HDF5 plain-path writeMinimal+readback still works");
        unlink([hPath fileSystemRepresentation]);
    }
}
