/*
 * TestStress — v0.9 M62 cross-language stress + concurrency.
 *
 * The existing TestQueryAndStreaming + TestHDF5 suites already cover
 * single-threaded 10K + 1M element benchmarks; this file adds:
 *
 *   1. Multi-thread concurrent reads from one file (4 readers)
 *   2. A timed 10K-spectrum write + reload + sampled-read cycle
 *      whose results are emitted as one-line "[obj-bench]" lines
 *      so the cross-language stress harness can scrape them.
 *
 * Cross-language coverage rationale: Python's M62 stress matrix
 * exercises the full 4-provider grid (HDF5/Memory/SQLite/Zarr).
 * ObjC + Java currently expose HDF5 only at the high-level
 * SpectralDataset entry point, so we benchmark HDF5 here. The
 * provider primitives themselves are tested cross-language by
 * TestCanonicalBytesCrossBackend already.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <pthread.h>

#import "Dataset/MPGOSpectralDataset.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *stressPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_stress_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *bytesAsF64(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf length:n encoding:enc axis:nil];
}

static MPGOMassSpectrum *makeSpectrum(NSUInteger k, NSUInteger nPeaks)
{
    double *mz = malloc(nPeaks * sizeof(double));
    double *intensity = malloc(nPeaks * sizeof(double));
    for (NSUInteger i = 0; i < nPeaks; i++) {
        mz[i]        = 100.0 + (double)k + (double)i * 0.1;
        intensity[i] = 1000.0 + (double)((k * 31 + i) % 1000);
    }
    MPGOSignalArray *mzArr  = bytesAsF64(mz, nPeaks);
    MPGOSignalArray *intArr = bytesAsF64(intensity, nPeaks);
    free(mz); free(intensity);
    NSError *err = nil;
    return [[MPGOMassSpectrum alloc] initWithMzArray:mzArr
                                       intensityArray:intArr
                                              msLevel:1
                                             polarity:MPGOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.06
                                          precursorMz:0.0
                                      precursorCharge:0
                                                error:&err];
}

// --- 4-thread concurrent-read state ----------------------------------

typedef struct {
    NSString *path;
    NSUInteger startIndex;
    NSUInteger count;
    NSUInteger seenSizes;  // accumulator: total peaks seen
    BOOL ok;
} ReaderArgs;

static void *concurrent_reader(void *arg)
{
    @autoreleasepool {
        ReaderArgs *a = (ReaderArgs *)arg;
        NSError *err = nil;
        MPGOSpectralDataset *ds =
            [MPGOSpectralDataset readFromFilePath:a->path error:&err];
        if (!ds) { a->ok = NO; return NULL; }
        MPGOAcquisitionRun *run = ds.msRuns[@"r"];
        if (!run || run.spectrumIndex.count == 0) { a->ok = NO; return NULL; }
        NSUInteger total = 0;
        for (NSUInteger i = 0; i < a->count; i++) {
            NSUInteger idx = (a->startIndex + i) % run.spectrumIndex.count;
            MPGOMassSpectrum *spec = [run objectAtIndex:idx];
            MPGOSignalArray *mz = spec.signalArrays[@"mz"];
            total += mz.length;
        }
        a->seenSizes = total;
        a->ok = YES;
    }
    return NULL;
}

void testStress(void)
{
    // ── Build a 10K-spectrum HDF5 .mpgo for the concurrency drill ──
    NSString *path = stressPath(@"10k");
    unlink([path fileSystemRepresentation]);

    NSDate *t0 = [NSDate date];
    NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:10000];
    for (NSUInteger k = 0; k < 10000; k++) {
        [spectra addObject:makeSpectrum(k, 16)];
    }
    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                     model:@"QE"
                                              serialNumber:@"S"
                                                sourceType:@"ESI"
                                              analyzerType:@"Orbitrap"
                                              detectorType:@"em"];
    MPGOAcquisitionRun *run =
        [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                    acquisitionMode:MPGOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"stress"
                              isaInvestigationId:@"ISA-STRESS"
                                          msRuns:@{@"r": run}
                                         nmrRuns:@{}
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                    transitions:nil];
    NSError *err = nil;
    BOOL wrote = [ds writeToFilePath:path error:&err];
    NSTimeInterval writeMs = -[t0 timeIntervalSinceNow] * 1000.0;
    PASS(wrote, "10K-spectrum stress fixture written to disk");
    printf("    [obj-bench] write 10K spectra HDF5 %.1f ms\n", writeMs);
    PASS(writeMs < 30000.0, "10K write under 30s soft target");

    // ── Sequential read sample ─────────────────────────────────────
    t0 = [NSDate date];
    MPGOSpectralDataset *back =
        [MPGOSpectralDataset readFromFilePath:path error:&err];
    PASS(back && back.msRuns[@"r"].spectrumIndex.count == 10000,
         "stress fixture re-opens with 10K spectra");
    MPGOAcquisitionRun *backRun = back.msRuns[@"r"];
    NSUInteger sampledTotal = 0;
    for (NSUInteger i = 0; i < 10000; i += 100) {
        MPGOMassSpectrum *spec = [backRun objectAtIndex:i];
        sampledTotal += spec.signalArrays[@"mz"].length;
    }
    NSTimeInterval readMs = -[t0 timeIntervalSinceNow] * 1000.0;
    printf("    [obj-bench] read 100/10K sampled %.1f ms (%lu peaks)\n",
           readMs, (unsigned long)sampledTotal);
    PASS(sampledTotal == 100 * 16, "sampled-read peak count matches");

    // ── 4-thread concurrent reads ──────────────────────────────────
    pthread_t threads[4];
    ReaderArgs args[4];
    for (int i = 0; i < 4; i++) {
        args[i].path = path;
        args[i].startIndex = (NSUInteger)i * 2500;
        args[i].count = 100;
        args[i].seenSizes = 0;
        args[i].ok = NO;
    }
    t0 = [NSDate date];
    for (int i = 0; i < 4; i++) {
        pthread_create(&threads[i], NULL, concurrent_reader, &args[i]);
    }
    for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
    NSTimeInterval concurrentMs = -[t0 timeIntervalSinceNow] * 1000.0;
    printf("    [obj-bench] 4 concurrent readers (100 spectra each) %.1f ms\n", concurrentMs);
    BOOL allOk = YES;
    NSUInteger summedPeaks = 0;
    for (int i = 0; i < 4; i++) {
        if (!args[i].ok) allOk = NO;
        summedPeaks += args[i].seenSizes;
    }
    PASS(allOk, "all 4 reader threads completed without error");
    PASS(summedPeaks == 4 * 100 * 16, "4 readers saw the expected peak total");

    unlink([path fileSystemRepresentation]);
}
