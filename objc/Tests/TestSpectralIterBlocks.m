/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * -[TTIOAcquisitionRun iterBlocksFrom:to:threads:error:usingBlock:] and
 * the unit plan behind it.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Run/TTIOSpectralUnitPlan.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectralStreamWriter.h"
#import "Run/TTIOSpectralBlockIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Providers/TTIOProviderRegistry.h"
#import <unistd.h>
#import "TTIOAcquisitionRun+Testing.h"

/* 6 spectra of 100 values; blocks start every 250 values, so no block
 * edge lands on a spectrum edge:
 *   spectra: [0,100) [100,200) [200,300) [300,400) [400,500) [500,600)
 *   blocks:  b0 [0,250)   b1 [250,500)   b2 [500,...)
 *   owner by first value: s0,s1,s2 -> b0 ; s3,s4 -> b1 ; s5 -> b2
 */
static void siuPlanBasics(void)
{
    unsigned long long off[6] = {0, 100, 200, 300, 400, 500};
    unsigned int len[6]       = {100, 100, 100, 100, 100, 100};
    unsigned long long bs[3]  = {0, 250, 500};

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:0 to:6
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:3];
    PASS(u.count == 3, "unit plan: 3 units for 6 spectra over 3 blocks (%lu)",
         (unsigned long)u.count);
    if (u.count != 3) return;

    TTIOSpectralUnit a; [u[0] getValue:&a];
    PASS(a.block == 0 && a.firstSpectrum == 0 && a.nSpectra == 3,
         "unit plan: b0 owns s0..s2 (block=%lu first=%lu n=%lu)",
         (unsigned long)a.block, (unsigned long)a.firstSpectrum,
         (unsigned long)a.nSpectra);
    PASS(a.valueStart == 0 && a.valueEnd == 300,
         "unit plan: b0 extent [0,300) (%llu,%llu)", a.valueStart, a.valueEnd);

    TTIOSpectralUnit b; [u[1] getValue:&b];
    PASS(b.block == 1 && b.firstSpectrum == 3 && b.nSpectra == 2,
         "unit plan: b1 owns s3..s4 (block=%lu first=%lu n=%lu)",
         (unsigned long)b.block, (unsigned long)b.firstSpectrum,
         (unsigned long)b.nSpectra);
    /* s4 ends at 500, which is b2's first value: the extent runs past
     * the owning block's end, so units are not byte independent. */
    PASS(b.valueStart == 300 && b.valueEnd == 500,
         "unit plan: b1 extent [300,500) crosses its own block end (%llu,%llu)",
         b.valueStart, b.valueEnd);

    TTIOSpectralUnit c; [u[2] getValue:&c];
    PASS(c.block == 2 && c.firstSpectrum == 5 && c.nSpectra == 1,
         "unit plan: b2 owns s5 (block=%lu first=%lu n=%lu)",
         (unsigned long)c.block, (unsigned long)c.firstSpectrum,
         (unsigned long)c.nSpectra);
}

/* A range starting part-way into a block reports run-global indices. */
static void siuPlanMidBlockStart(void)
{
    unsigned long long off[6] = {0, 100, 200, 300, 400, 500};
    unsigned int len[6]       = {100, 100, 100, 100, 100, 100};
    unsigned long long bs[3]  = {0, 250, 500};

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:1 to:4
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:3];
    PASS(u.count == 2, "unit plan: mid-block range spans 2 units (%lu)",
         (unsigned long)u.count);
    if (u.count != 2) return;

    TTIOSpectralUnit a; [u[0] getValue:&a];
    PASS(a.firstSpectrum == 1 && a.nSpectra == 2,
         "unit plan: clipped head unit is s1..s2 (first=%lu n=%lu)",
         (unsigned long)a.firstSpectrum, (unsigned long)a.nSpectra);
    PASS(a.valueStart == 100 && a.valueEnd == 300,
         "unit plan: clipped head extent [100,300) (%llu,%llu)",
         a.valueStart, a.valueEnd);

    TTIOSpectralUnit b; [u[1] getValue:&b];
    PASS(b.firstSpectrum == 3 && b.nSpectra == 1,
         "unit plan: clipped tail unit is s3 only (first=%lu n=%lu)",
         (unsigned long)b.firstSpectrum, (unsigned long)b.nSpectra);
}

/* One spectrum longer than a block: the blocks it spans own no spectrum
 * start and must not produce empty units. */
static void siuPlanSpectrumLongerThanBlock(void)
{
    unsigned long long off[2] = {0, 1000};
    unsigned int len[2]       = {1000, 10};
    unsigned long long bs[5]  = {0, 250, 500, 750, 1000};

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:0 to:2
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:5];
    PASS(u.count == 2, "unit plan: straddling spectrum yields 2 units, not 5 (%lu)",
         (unsigned long)u.count);
    BOOL noneEmpty = YES;
    for (NSValue *v in u) {
        TTIOSpectralUnit s; [v getValue:&s];
        if (s.nSpectra < 1) noneEmpty = NO;
    }
    PASS(noneEmpty, "unit plan: no empty unit emitted");
}

static void siuPlanEmptyRange(void)
{
    unsigned long long off[2] = {0, 100};
    unsigned int len[2]       = {100, 100};
    unsigned long long bs[1]  = {0};
    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:3 to:3
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:1];
    PASS(u.count == 0, "unit plan: empty range yields no units (%lu)",
         (unsigned long)u.count);
}

/* Every spectrum exactly once, no gaps, no overlap. */
static void siuPlanPartitions(void)
{
    const NSUInteger N = 97;
    unsigned long long off[97]; unsigned int len[97];
    unsigned long long cursor = 0;
    for (NSUInteger i = 0; i < N; i++) {
        len[i] = (unsigned int)(7 + (i % 13));
        off[i] = cursor; cursor += len[i];
    }
    unsigned long long bs[9];
    for (NSUInteger b = 0; b < 9; b++) bs[b] = b * (cursor / 9);

    NSArray<NSValue *> *u = [TTIOSpectralUnitPlan unitsForSpectraFrom:0 to:N
                                                             offsets:off lengths:len
                                                    blockValueStarts:bs count:9];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
    NSUInteger expectNext = 0;
    BOOL tiles = YES;
    for (NSValue *v in u) {
        TTIOSpectralUnit s; [v getValue:&s];
        if (s.firstSpectrum != expectNext) tiles = NO;
        [seen addIndexesInRange:NSMakeRange(s.firstSpectrum, s.nSpectra)];
        expectNext = s.firstSpectrum + s.nSpectra;
    }
    PASS(tiles, "unit plan: units tile without gaps or overlap");
    PASS(seen.count == N && expectNext == N,
         "unit plan: all %lu spectra covered exactly once (%lu)",
         (unsigned long)N, (unsigned long)seen.count);
}


/* ── end-to-end corpus ────────────────────────────────────────────────
 *
 * m/z[j] of spectrum i is 1000*i + j, so a spectrum's content names the
 * spectrum. Every assertion below checks that content, never an index
 * the callback derived from firstSpectrum.
 *
 * The FDZ1 block is 2^20 values and is not configurable, so the corpus
 * is sized past that on purpose: 1024 spectra x 1200 points is
 * 1228800 values per channel, which is 2 blocks. A smaller corpus would
 * be a single block and would never exercise a unit boundary.
 */
#define SIB_NSPEC 1024
#define SIB_NPTS  1200

static NSString *sibCorpusPath = nil;

static NSString *sibTmp(const char *tag)
{
    return [NSString stringWithFormat:@"/tmp/sib-%s-%d.tio", tag, (int)getpid()];
}

static id<TTIOStorageGroup> sibStudy(NSString *url, TTIOStorageOpenMode mode,
                                     id<TTIOStorageProvider> *pOut)
{
    NSError *err = nil;
    id<TTIOStorageProvider> p = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:mode provider:nil error:&err];
    if (!p) { NSLog(@"sib: open %@ failed: %@", url, err); return nil; }
    if (pOut) *pOut = p;
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    if (mode == TTIOStorageOpenModeCreate) {
        return [root createGroupNamed:@"study" error:&err];
    }
    return [root openGroupNamed:@"study" error:&err];
}

/* Writes the corpus once. Returns the path, or nil on failure. */
static NSString *sibWriteCorpus(void)
{
    NSString *path = sibTmp("corpus");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    NSError *err = nil;
    id<TTIOStorageProvider> prov = nil;
    id<TTIOStorageGroup> study = sibStudy(path, TTIOStorageOpenModeCreate, &prov);
    if (!study) return nil;

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
        initWithManufacturer:@"" model:@"" serialNumber:@"" sourceType:@""
                analyzerType:@"" detectorType:@""];
    TTIOSpectralStreamWriterOptions *o = [TTIOSpectralStreamWriterOptions
        msOptionsWithMode:TTIOAcquisitionModeMS1DDA
             channelNames:@[@"mz", @"intensity"] instrumentConfig:cfg];
    o.batchSpectra = 256;
    o.threads = 1;
    TTIOSpectralStreamWriter *w = [[TTIOSpectralStreamWriter alloc]
        initWithStudyGroup:study runName:@"r" options:o];

    BOOL ok = YES;
    NSMutableData *mzD = [NSMutableData dataWithLength:SIB_NPTS * sizeof(double)];
    NSMutableData *inD = [NSMutableData dataWithLength:SIB_NPTS * sizeof(double)];
    for (NSUInteger k = 0; k < SIB_NSPEC && ok; k++) {
        double *mz = mzD.mutableBytes, *in = inD.mutableBytes;
        for (NSUInteger j = 0; j < SIB_NPTS; j++) {
            mz[j] = (double)(1000 * k + j);   /* content names the spectrum */
            in[j] = (double)((k * 7 + j) % 977);
        }
        TTIOSignalArray *mzA = [[TTIOSignalArray alloc] initWithBuffer:[mzD copy]
                                                                length:SIB_NPTS
                                                              encoding:enc axis:nil];
        TTIOSignalArray *inA = [[TTIOSignalArray alloc] initWithBuffer:[inD copy]
                                                                length:SIB_NPTS
                                                              encoding:enc axis:nil];
        TTIOMassSpectrum *sp = [[TTIOMassSpectrum alloc]
            initWithMzArray:mzA intensityArray:inA msLevel:1
                   polarity:TTIOPolarityPositive scanWindow:nil indexPosition:k
            scanTimeSeconds:(double)k * 0.01 precursorMz:0 precursorCharge:0 error:NULL];
        ok = ok && [w appendSpectrum:sp error:&err];
    }
    ok = ok && [w close:&err];
    [prov close];
    if (!ok) {
        PASS(NO, "iterBlocks: corpus write (%s)",
             [[err localizedDescription] UTF8String] ?: "");
        return nil;
    }
    return path;
}

static TTIOAcquisitionRun *sibOpen(NSString *path, id<TTIOStorageProvider> *provOut)
{
    NSError *err = nil;
    id<TTIOStorageGroup> study = sibStudy(path, TTIOStorageOpenModeRead, provOut);
    if (!study) return nil;
    id<TTIOStorageGroup> runs = [study openGroupNamed:@"ms_runs" error:&err];
    if (!runs) return nil;
    return [TTIOAcquisitionRun readFromGroup:runs name:@"r" error:&err];
}

/* The visitor must see, for run index i, the m/z content of spectrum i. */
static void sibContentMatches(NSUInteger threads, NSUInteger from, NSUInteger to)
{
    id<TTIOStorageProvider> prov = nil;
    TTIOAcquisitionRun *run = sibOpen(sibCorpusPath, &prov);
    if (!run) { PASS(NO, "iterBlocks: corpus opens (threads=%lu)",
                     (unsigned long)threads); return; }

    NSMutableDictionary<NSNumber *, NSNumber *> *got = [NSMutableDictionary dictionary];
    NSLock *lock = [NSLock new];
    __block NSUInteger units = 0;
    NSError *err = nil;
    BOOL ok = [run iterBlocksFrom:from to:to threads:threads error:&err
                       usingBlock:^(TTIOAcquisitionRun *view, NSUInteger viewStart,
                                    NSUInteger firstSpectrum, NSUInteger nSpectra,
                                    BOOL *stop) {
        NSMutableDictionary *local = [NSMutableDictionary dictionary];
        for (NSUInteger k = 0; k < nSpectra; k++) {
            TTIOMassSpectrum *sp = [view spectrumAtIndex:viewStart + k error:NULL];
            NSData *buf = [sp.mzArray float64Buffer];
            const double *v = buf.bytes;
            local[@(firstSpectrum + k)] = @(v[0]);
        }
        [lock lock];
        [got addEntriesFromDictionary:local];
        units++;
        [lock unlock];
    }];

    PASS(ok, "iterBlocks: threads=%lu [%lu,%lu) returns YES (%s)",
         (unsigned long)threads, (unsigned long)from, (unsigned long)to,
         [[err localizedDescription] UTF8String] ?: "");
    PASS(got.count == to - from,
         "iterBlocks: threads=%lu visited %lu spectra, expected %lu (%lu units)",
         (unsigned long)threads, (unsigned long)got.count,
         (unsigned long)(to - from), (unsigned long)units);

    NSUInteger wrong = 0; NSUInteger firstBad = 0; double badVal = 0;
    for (NSUInteger i = from; i < to; i++) {
        NSNumber *g = got[@(i)];
        if (!g || fabs(g.doubleValue - (double)(1000 * i)) > 1e-9) {
            if (!wrong) { firstBad = i; badVal = g ? g.doubleValue : -1.0; }
            wrong++;
        }
    }
    PASS(wrong == 0,
         "iterBlocks: threads=%lu every spectrum carries its own content "
         "(%lu wrong, first %lu had m/z[0]=%.1f expected %.1f)",
         (unsigned long)threads, (unsigned long)wrong, (unsigned long)firstBad,
         badVal, (double)(1000 * firstBad));

    [prov close];
}

/* The corpus must span more than one FDZ1 block, or no test here ever
 * crosses a unit boundary and the whole exercise proves nothing. */
static void sibCorpusSpansSeveralBlocks(void)
{
    id<TTIOStorageProvider> prov = nil;
    TTIOAcquisitionRun *run = sibOpen(sibCorpusPath, &prov);
    if (!run) { PASS(NO, "iterBlocks: corpus opens for the block count"); return; }
    __block NSUInteger units = 0;
    NSLock *lock = [NSLock new];
    [run iterBlocksFrom:0 to:SIB_NSPEC threads:1 error:NULL
             usingBlock:^(TTIOAcquisitionRun *view, NSUInteger viewStart,
                          NSUInteger firstSpectrum, NSUInteger nSpectra, BOOL *stop) {
        [lock lock]; units++; [lock unlock];
    }];
    PASS(units >= 2,
         "iterBlocks: corpus spans %lu units, so a unit boundary is exercised",
         (unsigned long)units);
    [prov close];
}

static void sibSerial(void)
{
    sibCorpusSpansSeveralBlocks();
    sibContentMatches(1, 0, SIB_NSPEC);
    sibContentMatches(1, 7, SIB_NSPEC - 11);   /* starts and ends mid-block */
}

/* Memory governs the window, not the thread count. */
static void sibWindowIsMemoryGoverned(void)
{
    id<TTIOStorageProvider> prov = nil;
    TTIOAcquisitionRun *run = sibOpen(sibCorpusPath, &prov);
    if (!run) { PASS(NO, "iterBlocks: corpus opens for the window test"); return; }

    NSArray<NSValue *> *units = [run _unitsFrom:0 to:SIB_NSPEC];
    PASS(units.count >= 2, "iterBlocks: window test has %lu units",
         (unsigned long)units.count);

    setenv("TTIO_MEMORY_BUDGET", "1", 1);
    NSUInteger tight = [run _unitWindowForThreads:30 units:units];
    unsetenv("TTIO_MEMORY_BUDGET");
    PASS(tight == 1,
         "iterBlocks: a 1-byte budget admits 1 unit even at 30 threads (%lu)",
         (unsigned long)tight);

    NSUInteger open = [run _unitWindowForThreads:30 units:units];
    PASS(open <= units.count,
         "iterBlocks: window never exceeds the unit count (%lu <= %lu)",
         (unsigned long)open, (unsigned long)units.count);
    PASS(open >= 1, "iterBlocks: window is at least 1 (%lu)", (unsigned long)open);

    NSUInteger one = [run _unitWindowForThreads:1 units:units];
    PASS(one == 1, "iterBlocks: 1 thread gives a window of 1 (%lu)",
         (unsigned long)one);

    [prov close];
}

void testSpectralIterBlocks(void)
{
    siuPlanBasics();
    siuPlanMidBlockStart();
    siuPlanSpectrumLongerThanBlock();
    siuPlanEmptyRange();
    siuPlanPartitions();

    sibCorpusPath = sibWriteCorpus();
    if (!sibCorpusPath) return;
    sibSerial();
    sibWindowIsMemoryGoverned();
    [[NSFileManager defaultManager] removeItemAtPath:sibCorpusPath error:NULL];
}
