/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOSpectralStreamWriter against -[TTIOAcquisitionRun writeToGroup:],
 * the finalised codec-17 header, channelRange and iterSpectra.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Import/TTIOMzMLReader.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Run/TTIOInstrumentConfig.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Run/TTIOSpectralBlockIndex.h"
#import "Run/TTIOSpectralStreamWriter.h"
#import "Run/TTIOWrittenSpectralBatch.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "Codecs/TTIOFloatDeltaZstd.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOStorageProtocols.h"
#include <math.h>
#include <unistd.h>

static NSString *sswFixture(void)
{
    for (NSString *p in @[@"Tests/Fixtures/1min.mzML", @"Fixtures/1min.mzML",
                          @"/home/toddw/TTI-O/objc/Tests/Fixtures/1min.mzML"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

static NSString *sswTmp(const char *tag)
{
    return [NSString stringWithFormat:@"/tmp/ssw-%s-%d.tio", tag, (int)getpid()];
}

static id<TTIOStorageGroup> sswStudy(NSString *url, TTIOStorageOpenMode mode, id<TTIOStorageProvider> *pOut)
{
    NSError *err = nil;
    id<TTIOStorageProvider> p = [[TTIOProviderRegistry sharedRegistry] openURL:url mode:mode provider:nil error:&err];
    if (!p) { NSLog(@"open %@ failed: %@", url, err); return nil; }
    if (pOut) *pOut = p;
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    if (mode == TTIOStorageOpenModeCreate) return [root createGroupNamed:@"study" error:&err];
    return [root openGroupNamed:@"study" error:&err];
}

static BOOL sswSameSpectra(TTIOAcquisitionRun *a, TTIOAcquisitionRun *b, NSString **why)
{
    if (a.count != b.count) { *why = @"count"; return NO; }
    for (NSUInteger i = 0; i < a.count; i++) {
        TTIOMassSpectrum *sa = [a spectrumAtIndex:i error:NULL], *sb = [b spectrumAtIndex:i error:NULL];
        if (!sa || !sb) { *why = [NSString stringWithFormat:@"spectrum %lu nil", (unsigned long)i]; return NO; }
        if (![[sa.mzArray float64Buffer] isEqualToData:[sb.mzArray float64Buffer]]
            || ![[sa.intensityArray float64Buffer] isEqualToData:[sb.intensityArray float64Buffer]]
            || sa.msLevel != sb.msLevel || sa.polarity != sb.polarity
            || sa.scanTimeSeconds != sb.scanTimeSeconds || sa.precursorMz != sb.precursorMz) {
            *why = [NSString stringWithFormat:@"spectrum %lu differs: mz %lu/%lu eq=%d int %lu/%lu eq=%d ms %lu/%lu pol %ld/%ld rt %g/%g pmz %g/%g",
                    (unsigned long)i, (unsigned long)sa.mzArray.length, (unsigned long)sb.mzArray.length,
                    [[sa.mzArray float64Buffer] isEqualToData:[sb.mzArray float64Buffer]],
                    (unsigned long)sa.intensityArray.length, (unsigned long)sb.intensityArray.length,
                    [[sa.intensityArray float64Buffer] isEqualToData:[sb.intensityArray float64Buffer]],
                    (unsigned long)sa.msLevel, (unsigned long)sb.msLevel, (long)sa.polarity, (long)sb.polarity,
                    sa.scanTimeSeconds, sb.scanTimeSeconds, sa.precursorMz, sb.precursorMz];
            return NO;
        }
    }
    return YES;
}

static void sswStreamedEqualsEager(void)
{
    NSString *fx = sswFixture();
    if (!fx) { PASS(YES, "spectral stream: 1min.mzML unavailable, skipped"); return; }
    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOMzMLReader readFromFilePath:fx error:&err];
    TTIOAcquisitionRun *src = [ds.msRuns.allValues firstObject];
    PASS(src != nil && src.count > 0, "spectral stream: fixture run (%lu spectra)", (unsigned long)src.count);
    NSArray *spectra = [src spectra];

    NSString *eager = sswTmp("eager"), *streamed = sswTmp("streamed");
    [[NSFileManager defaultManager] removeItemAtPath:eager error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:streamed error:NULL];
    id<TTIOStorageProvider> pe = nil, ps = nil;
    id<TTIOStorageGroup> se = sswStudy(eager, TTIOStorageOpenModeCreate, &pe);
    id<TTIOStorageGroup> seRuns = [se createGroupNamed:@"ms_runs" error:&err];
    [seRuns setAttributeValue:@"r" forName:@"_run_names" error:&err];
    PASS([src writeToGroup:seRuns name:@"r" error:&err], "spectral stream: eager write (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    [pe close];

    id<TTIOStorageGroup> ss = sswStudy(streamed, TTIOStorageOpenModeCreate, &ps);
    TTIOSpectralStreamWriterOptions *o = [TTIOSpectralStreamWriterOptions msOptionsWithMode:src.acquisitionMode
        channelNames:@[@"mz", @"intensity"] instrumentConfig:src.instrumentConfig];
    o.batchSpectra = 7;
    TTIOSpectralStreamWriter *w = [[TTIOSpectralStreamWriter alloc] initWithStudyGroup:ss runName:@"r" options:o];
    BOOL ok = YES;
    for (TTIOSpectrum *s in spectra) { ok = ok && [w appendSpectrum:s error:&err]; }
    PASS(ok, "spectral stream: appendSpectrum x%lu (%s)", (unsigned long)spectra.count,
         [[err localizedDescription] UTF8String] ?: "");
    PASS(w.spectrumCount == spectra.count, "spectral stream: spectrumCount before close");
    PASS([w close:&err], "spectral stream: close (%s)", [[err localizedDescription] UTF8String] ?: "");
    [ps close];

    id<TTIOStorageProvider> re = nil, rs = nil;
    id<TTIOStorageGroup> ge = sswStudy(eager, TTIOStorageOpenModeRead, &re);
    id<TTIOStorageGroup> gs = sswStudy(streamed, TTIOStorageOpenModeRead, &rs);
    TTIOAcquisitionRun *runE = [TTIOAcquisitionRun readFromGroup:[ge openGroupNamed:@"ms_runs" error:&err] name:@"r" error:&err];
    TTIOAcquisitionRun *runS = [TTIOAcquisitionRun readFromGroup:[gs openGroupNamed:@"ms_runs" error:&err] name:@"r" error:&err];
    PASS(runE != nil && runS != nil, "spectral stream: both runs open (%s)", [[err localizedDescription] UTF8String] ?: "");
    NSString *why = nil;
    PASS(sswSameSpectra(runE, runS, &why), "spectral stream: streamed spectra equal eager (%s)", [why UTF8String] ?: "");
    PASS(runS.signalCompression == TTIOCompressionFloatDeltaZstd, "spectral stream: codec 17 on the streamed run");
    PASS([[[[gs openGroupNamed:@"ms_runs" error:NULL] attributeValueForName:@"_run_names" error:NULL] description]
             isEqualToString:@"r"],
         "spectral stream: ms_runs/@_run_names maintained");
    // The channel dataset bytes: same values, same blocks, so the FDZ1
    // streams are byte-identical and the header names every value.
    id<TTIOStorageGroup> scE = [[[ge openGroupNamed:@"ms_runs" error:NULL] openGroupNamed:@"r" error:NULL]
                                openGroupNamed:@"signal_channels" error:NULL];
    id<TTIOStorageDataset> mzE = [scE openDatasetNamed:@"mz_values" error:NULL];
    id<TTIOStorageDataset> mzS = [[[[gs openGroupNamed:@"ms_runs" error:NULL] openGroupNamed:@"r" error:NULL]
                                   openGroupNamed:@"signal_channels" error:NULL] openDatasetNamed:@"mz_values" error:NULL];
    NSData *bytesE = [mzE readAll:NULL], *bytesS = [mzS readAll:NULL];
    PASS([bytesE isEqualToData:bytesS], "spectral stream: mz_values FDZ1 bytes identical (%lu vs %lu)",
         (unsigned long)bytesE.length, (unsigned long)bytesS.length);
    PASS([mzS isExtendable], "spectral stream: streamed channel dataset is extendable");
    TTIOFDZBlockTable *t = [TTIOFloatDeltaZstd readBlockTableWithReader:^NSData *(NSUInteger off, NSUInteger n) {
        return [bytesS subdataWithRange:NSMakeRange(off, MIN(n, bytesS.length - off))];
    } error:&err];
    NSUInteger total = 0;
    for (NSUInteger i = 0; i < runS.spectrumIndex.count; i++) total += [runS.spectrumIndex lengthAt:i];
    PASS(t != nil && t.nValues == total && t.nBlocks == (total + [TTIOFloatDeltaZstd blockSize] - 1) / [TTIOFloatDeltaZstd blockSize],
         "spectral stream: header finalised (%llu values, %u blocks)", t ? t.nValues : 0ULL, t ? t.nBlocks : 0U);
    // channelRange: a spectrum's slice, and a range spanning spectra.
    NSUInteger i0 = runS.count > 3 ? 3 : 0;
    NSUInteger off0 = (NSUInteger)[runS.spectrumIndex offsetAt:i0], len0 = [runS.spectrumIndex lengthAt:i0];
    TTIOMassSpectrum *s0 = [runS spectrumAtIndex:i0 error:&err];
    NSData *r0 = [runS channelRange:@"mz" start:off0 count:len0 error:&err];
    PASS(r0 != nil && [r0 isEqualToData:s0.mzArray.buffer], "spectral stream: channelRange equals the spectrum slice");
    NSUInteger i1 = MIN(runS.count - 1, i0 + 2);
    NSUInteger end1 = (NSUInteger)[runS.spectrumIndex offsetAt:i1] + [runS.spectrumIndex lengthAt:i1];
    NSData *span = [runS channelRange:@"intensity" start:off0 count:end1 - off0 error:&err];
    NSMutableData *cat = [NSMutableData data];
    for (NSUInteger i = i0; i <= i1; i++) [cat appendData:[(TTIOMassSpectrum *)[runS spectrumAtIndex:i error:NULL] intensityArray].buffer];
    PASS(span != nil && [span isEqualToData:cat], "spectral stream: channelRange across spectra");
    PASS([runS channelRange:@"mz" start:total count:1 error:NULL] == nil, "spectral stream: channelRange past the end is nil");
    // iterSpectra == spectrumAtIndex.
    __block NSUInteger seen = 0;
    __block BOOL same = YES;
    ok = [runS iterSpectraWithBatch:5 error:&err usingBlock:^(id sp, NSUInteger index, BOOL *stop) {
        (void)stop;
        TTIOMassSpectrum *ref = [runS spectrumAtIndex:index error:NULL];
        if (![[(TTIOMassSpectrum *)sp mzArray].buffer isEqualToData:ref.mzArray.buffer]
            || ![[(TTIOMassSpectrum *)sp intensityArray].buffer isEqualToData:ref.intensityArray.buffer]) same = NO;
        seen++;
    }];
    PASS(ok && same && seen == runS.count, "spectral stream: iterSpectra equals spectrumAtIndex (%lu)", (unsigned long)seen);
    // The eager run also reads through the block-wise path.
    PASS(sswSameSpectra(runE, runS, &why), "spectral stream: eager run reads block-wise (%s)", [why UTF8String] ?: "");
    [re close];
    [rs close];
    [[NSFileManager defaultManager] removeItemAtPath:eager error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:streamed error:NULL];
}

static void sswZlibAndMemory(void)
{
    NSString *fx = sswFixture();
    if (!fx) return;
    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOMzMLReader readFromFilePath:fx error:&err];
    TTIOAcquisitionRun *src = [ds.msRuns.allValues firstObject];
    NSArray *spectra = [src spectra];
    // zlib float64 (no codec 17), memory provider, one batch object.
    NSString *url = [NSString stringWithFormat:@"memory://ssw-zlib-%d", (int)getpid()];
    [TTIOMemoryProvider discardStore:url];
    id<TTIOStorageProvider> p = nil;
    id<TTIOStorageGroup> study = sswStudy(url, TTIOStorageOpenModeCreate, &p);
    TTIOSpectralStreamWriterOptions *o = [TTIOSpectralStreamWriterOptions msOptionsWithMode:src.acquisitionMode
        channelNames:@[@"mz", @"intensity"] instrumentConfig:nil];
    o.optDisableFloatDelta = YES;
    TTIOSpectralStreamWriter *w = [[TTIOSpectralStreamWriter alloc] initWithStudyGroup:study runName:@"z" options:o];
    NSUInteger half = spectra.count / 2;
    TTIOWrittenSpectralBatch *b1 = [TTIOWrittenSpectralBatch batchWithSpectra:[spectra subarrayWithRange:NSMakeRange(0, half)]
                                                                 channelNames:o.channelNames];
    BOOL ok = [w appendBatch:b1 error:&err];
    for (NSUInteger i = half; i < spectra.count; i++) ok = ok && [w appendSpectrum:spectra[i] error:&err];
    ok = ok && [w close:&err];
    PASS(ok, "spectral stream: zlib/memory write (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOAcquisitionRun *back = [TTIOAcquisitionRun readFromGroup:[study openGroupNamed:@"ms_runs" error:&err]
                                                            name:@"z" error:&err];
    NSString *why = nil;
    PASS(back != nil && sswSameSpectra(src, back, &why), "spectral stream: zlib/memory streamed equals source (%s)",
         [why UTF8String] ?: "");
    PASS(back.signalCompression == TTIOCompressionZlib, "spectral stream: zlib run has no codec 17");
    [p close];
    [TTIOMemoryProvider discardStore:url];
}

static NSArray<TTIOMassSpectrum *> *sswSynthSpectra(NSUInteger nSpec, NSUInteger nPts, unsigned seed)
{
    srand(seed);
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:nSpec];
    NSMutableData *mzD = [NSMutableData dataWithLength:nPts * sizeof(double)];
    NSMutableData *inD = [NSMutableData dataWithLength:nPts * sizeof(double)];
    for (NSUInteger k = 0; k < nSpec; k++) {
        double *mz = mzD.mutableBytes, *in = inD.mutableBytes;
        double base = 100.0 + (double)(k % 977);
        for (NSUInteger i = 0; i < nPts; i++) {
            mz[i] = base + (double)i * 0.37 + (double)(rand() % 1000) * 1e-4;
            in[i] = (double)(rand() % 100000) * 0.1;
        }
        TTIOSignalArray *mzA = [[TTIOSignalArray alloc] initWithBuffer:[mzD copy] length:nPts encoding:enc axis:nil];
        TTIOSignalArray *inA = [[TTIOSignalArray alloc] initWithBuffer:[inD copy] length:nPts encoding:enc axis:nil];
        [spectra addObject:[[TTIOMassSpectrum alloc]
            initWithMzArray:mzA intensityArray:inA msLevel:1
                   polarity:TTIOPolarityPositive scanWindow:nil indexPosition:k
            scanTimeSeconds:(double)k * 0.01 precursorMz:0 precursorCharge:0 error:NULL]];
    }
    return spectra;
}

/* Write the spectra with the given thread count; the path's study holds
 * run "r". */
static BOOL sswWriteSynth(NSString *path, NSArray<TTIOMassSpectrum *> *spectra, NSUInteger threads)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSError *err = nil;
    id<TTIOStorageProvider> prov = nil;
    id<TTIOStorageGroup> study = sswStudy(path, TTIOStorageOpenModeCreate, &prov);
    TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
        initWithManufacturer:@"" model:@"" serialNumber:@"" sourceType:@""
                analyzerType:@"" detectorType:@""];
    TTIOSpectralStreamWriterOptions *o = [TTIOSpectralStreamWriterOptions
        msOptionsWithMode:TTIOAcquisitionModeMS1DDA
             channelNames:@[@"mz", @"intensity"] instrumentConfig:cfg];
    o.batchSpectra = 1000;
    o.threads = threads;
    TTIOSpectralStreamWriter *w = [[TTIOSpectralStreamWriter alloc]
        initWithStudyGroup:study runName:@"r" options:o];
    if (w.threads != threads) { PASS(NO, "bp-ms: writer threads resolved"); return NO; }
    BOOL ok = YES;
    for (TTIOMassSpectrum *sp in spectra) { ok = ok && [w appendSpectrum:sp error:&err]; }
    ok = ok && [w close:&err];
    [prov close];
    if (!ok) PASS(NO, "bp-ms: write threads=%lu (%s)", (unsigned long)threads,
                  [[err localizedDescription] UTF8String] ?: "");
    return ok;
}

static NSData *sswChannelBytes(NSString *path, NSString *name)
{
    id<TTIOStorageProvider> prov = nil;
    id<TTIOStorageGroup> study = sswStudy(path, TTIOStorageOpenModeRead, &prov);
    id<TTIOStorageDataset> ds = [[[[study openGroupNamed:@"ms_runs" error:NULL]
        openGroupNamed:@"r" error:NULL] openGroupNamed:@"signal_channels" error:NULL]
        openDatasetNamed:name error:NULL];
    NSData *d = [ds readAll:NULL];
    [prov close];
    return d;
}

static void sswThreadedByteIdentical(void)
{
    NSArray *spectra = sswSynthSpectra(40000, 64, 13);
    NSString *a = sswTmp("bp-serial"), *b = sswTmp("bp-threaded");
    if (!sswWriteSynth(a, spectra, 1) || !sswWriteSynth(b, spectra, 5)) return;
    for (NSString *ch in @[@"mz_values", @"intensity_values"]) {
        NSData *da = sswChannelBytes(a, ch), *db = sswChannelBytes(b, ch);
        PASS(da != nil && [da isEqualToData:db],
             "bp-ms: %s FDZ1 bytes identical threads=1 vs 5 (%lu vs %lu)",
             [ch UTF8String], (unsigned long)da.length, (unsigned long)db.length);
    }

    // Threaded reads on the threads=5 file.
    NSError *err = nil;
    id<TTIOStorageProvider> prov = nil;
    id<TTIOStorageGroup> study = sswStudy(b, TTIOStorageOpenModeRead, &prov);
    TTIOAcquisitionRun *run = [TTIOAcquisitionRun
        readFromGroup:[study openGroupNamed:@"ms_runs" error:&err] name:@"r" error:&err];
    PASS(run != nil && run.count == spectra.count, "bp-ms: streamed run open (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    if (!run) { [prov close]; return; }
    NSUInteger totalV = 0;
    for (NSUInteger i = 0; i < run.spectrumIndex.count; i++) totalV += [run.spectrumIndex lengthAt:i];
    NSData *serialR = [run channelRange:@"mz" start:1000 count:totalV - 2000 threads:1 error:&err];
    NSData *threadedR = [run channelRange:@"mz" start:1000 count:totalV - 2000 threads:4 error:&err];
    PASS(serialR != nil && [serialR isEqualToData:threadedR],
         "bp-ms: channelRange threads=4 equals serial (%lu values)",
         (unsigned long)(serialR.length / sizeof(double)));

    NSMutableArray *sums1 = [NSMutableArray array], *sums4 = [NSMutableArray array];
    BOOL ok1 = [run iterSpectraWithBatch:4096 threads:1 error:&err
                              usingBlock:^(id sp, NSUInteger index, BOOL *stop) {
        TTIOSignalArray *ia = ((TTIOMassSpectrum *)sp).intensityArray;
        const double *v = [ia float64Buffer].bytes;
        double t = 0; for (NSUInteger i = 0; i < ia.length; i++) t += v[i];
        [sums1 addObject:@(t)];
    }];
    BOOL ok4 = [run iterSpectraWithBatch:4096 threads:4 error:&err
                              usingBlock:^(id sp, NSUInteger index, BOOL *stop) {
        TTIOSignalArray *ia = ((TTIOMassSpectrum *)sp).intensityArray;
        const double *v = [ia float64Buffer].bytes;
        double t = 0; for (NSUInteger i = 0; i < ia.length; i++) t += v[i];
        [sums4 addObject:@(t)];
    }];
    PASS(ok1 && ok4 && sums1.count == spectra.count && [sums1 isEqualToArray:sums4],
         "bp-ms: iterSpectra threads=4 equals serial (%lu spectra)", (unsigned long)sums4.count);
    [prov close];
    [[NSFileManager defaultManager] removeItemAtPath:a error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:b error:NULL];
}


/* blocks/index on an MS run: the spectral counterpart of the genomic
 * block table. Every row must name bytes that are the block for the
 * value range it claims. */
static void sswBlockIndex(void)
{
    /* 40000 spectra of 64 points is 2 560 000 values: three FDZ blocks
     * with a short one at the end. */
    NSArray *spectra = sswSynthSpectra(40000, 64, 21);
    NSString *path = sswTmp("block-index");
    if (!sswWriteSynth(path, spectra, 1)) return;
    const unsigned long long totalValues = 40000ULL * 64ULL;

    NSError *err = nil;
    id<TTIOStorageProvider> prov = nil;
    id<TTIOStorageGroup> study = sswStudy(path, TTIOStorageOpenModeRead, &prov);
    id<TTIOStorageGroup> run = [[study openGroupNamed:@"ms_runs" error:&err]
                                    openGroupNamed:@"r" error:&err];
    PASS(run != nil, "bi: run group opens");

    TTIOSpectralBlockIndex *bi = [TTIOSpectralBlockIndex readFromRunGroup:run error:&err];
    PASS(bi != nil, "bi: blocks/index present on an FDZ-compressed MS run");
    if (!bi) { [prov close]; return; }

    NSUInteger expected = (NSUInteger)((totalValues + [TTIOFloatDeltaZstd blockSize] - 1)
                                       / [TTIOFloatDeltaZstd blockSize]);
    PASS(bi.count == expected, "bi: one row per FDZ block (%lu)", (unsigned long)bi.count);
    PASS(bi.valueCount == totalValues, "bi: rows account for every value");
    PASS(bi.channelNames.count == 2, "bi: both channels named in the table");

    BOOL tiles = YES;
    unsigned long long cursor = 0;
    for (NSUInteger k = 0; k < bi.count; k++) {
        if ([bi valueStartAt:k] != cursor) tiles = NO;
        cursor += [bi valuesAt:k];
    }
    PASS(tiles && cursor == totalValues, "bi: block value ranges tile the channel");

    PASS([bi codecOf:@"mz" at:0] == (NSUInteger)TTIOCompressionFloatDeltaZstd,
         "bi: table records codec 17 for mz");
    PASS([bi blockForValue:0] == 0, "bi: value 0 maps to block 0");
    PASS([bi blockForValue:totalValues - 1] == bi.count - 1,
         "bi: the last value maps to the last block");
    PASS([bi blockForValue:totalValues] == NSNotFound,
         "bi: a value past the end has no block");

    /* Every recorded extent must be exactly one self-describing block:
     * a 5-byte header whose length field accounts for the rest. */
    BOOL extentsAgree = YES, transformsKnown = YES;
    for (NSString *ch in @[@"mz", @"intensity"]) {
        NSData *all = sswChannelBytes(path, [ch stringByAppendingString:@"_values"]);
        const uint8_t *p = all.bytes;
        for (NSUInteger k = 0; k < bi.count; k++) {
            unsigned long long off = [bi offsetOf:ch at:k];
            unsigned long long len = [bi lengthOf:ch at:k];
            if (off + len > all.length || len < 5) { extentsAgree = NO; break; }
            uint32_t bodyLen = (uint32_t)p[off + 1] | ((uint32_t)p[off + 2] << 8)
                             | ((uint32_t)p[off + 3] << 16) | ((uint32_t)p[off + 4] << 24);
            if (5 + (unsigned long long)bodyLen != len) extentsAgree = NO;
            if ((p[off] & ~0x03) != 0) transformsKnown = NO;
        }
    }
    PASS(extentsAgree, "bi: every extent is one block, header length included");
    PASS(transformsKnown, "bi: every block header carries a known transform");

    [prov close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

/* A run written without codec 17 has no blocks to describe. */
static void sswBlockIndexAbsentWithoutFdz(void)
{
    NSArray *spectra = sswSynthSpectra(50, 32, 5);
    NSString *path = sswTmp("block-index-none");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSError *err = nil;
    id<TTIOStorageProvider> prov = nil;
    id<TTIOStorageGroup> study = sswStudy(path, TTIOStorageOpenModeCreate, &prov);
    TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
        initWithManufacturer:@"" model:@"" serialNumber:@"" sourceType:@""
                analyzerType:@"" detectorType:@""];
    TTIOSpectralStreamWriterOptions *o = [TTIOSpectralStreamWriterOptions
        msOptionsWithMode:TTIOAcquisitionModeMS1DDA
             channelNames:@[@"mz", @"intensity"] instrumentConfig:cfg];
    o.signalCompression = TTIOCompressionZlib;
    o.optDisableFloatDelta = YES;
    TTIOSpectralStreamWriter *w = [[TTIOSpectralStreamWriter alloc]
        initWithStudyGroup:study runName:@"r" options:o];
    BOOL ok = YES;
    for (TTIOMassSpectrum *sp in spectra) ok = ok && [w appendSpectrum:sp error:&err];
    ok = ok && [w close:&err];
    [prov close];
    PASS(ok, "bi: zlib run written");

    prov = nil;
    study = sswStudy(path, TTIOStorageOpenModeRead, &prov);
    id<TTIOStorageGroup> run = [[study openGroupNamed:@"ms_runs" error:&err]
                                    openGroupNamed:@"r" error:&err];
    TTIOSpectralBlockIndex *bi = [TTIOSpectralBlockIndex readFromRunGroup:run error:NULL];
    PASS(bi == nil, "bi: no blocks/index on a run without codec 17");
    [prov close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

/* base_peak_intensities is computed by scanning -float64Buffer, which
 * returns a freshly allocated conversion buffer for any precision
 * other than float64. A float32 intensity array is the ordinary case
 * for real mzML and is the one that takes that path. */
static void sswBasePeakFromFloat32Intensity(void)
{
    const NSUInteger nSpec = 64, nPts = 128;
    TTIOEncodingSpec *enc32 =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat32
                       compressionAlgorithm:TTIOCompressionNone
                                  byteOrder:TTIOByteOrderLittleEndian];
    TTIOEncodingSpec *enc64 =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionNone
                                  byteOrder:TTIOByteOrderLittleEndian];

    NSMutableArray<TTIOMassSpectrum *> *spectra = [NSMutableArray array];
    NSMutableArray<NSNumber *> *expected = [NSMutableArray array];
    for (NSUInteger k = 0; k < nSpec; k++) {
        NSMutableData *mzD = [NSMutableData dataWithLength:nPts * sizeof(double)];
        NSMutableData *inD = [NSMutableData dataWithLength:nPts * sizeof(float)];
        double *mz = mzD.mutableBytes;
        float *in = inD.mutableBytes;
        float peak = 0;
        for (NSUInteger i = 0; i < nPts; i++) {
            mz[i] = 100.0 + (double)i * 0.5;
            in[i] = (float)((k * 31 + i * 7) % 977) + 1.0f;
            if (in[i] > peak) peak = in[i];
        }
        [expected addObject:@((double)peak)];
        TTIOSignalArray *mzA = [[TTIOSignalArray alloc] initWithBuffer:mzD length:nPts
                                                              encoding:enc64 axis:nil];
        TTIOSignalArray *inA = [[TTIOSignalArray alloc] initWithBuffer:inD length:nPts
                                                              encoding:enc32 axis:nil];
        [spectra addObject:[[TTIOMassSpectrum alloc]
            initWithMzArray:mzA intensityArray:inA msLevel:1
                   polarity:TTIOPolarityPositive scanWindow:nil indexPosition:k
            scanTimeSeconds:(double)k precursorMz:0 precursorCharge:0 error:NULL]];
    }

    TTIOWrittenSpectralBatch *b =
        [TTIOWrittenSpectralBatch batchWithSpectra:spectra
                                      channelNames:@[@"mz", @"intensity"]];
    PASS(b != nil, "bpi: batch built from float32 intensity arrays");
    const double *got = b.basePeakIntensities.bytes;
    BOOL allMatch = (b.basePeakIntensities.length == nSpec * sizeof(double));
    for (NSUInteger k = 0; allMatch && k < nSpec; k++) {
        if (fabs(got[k] - [expected[k] doubleValue]) > 1e-9) allMatch = NO;
    }
    PASS(allMatch, "bpi: base peak of a float32 intensity array is the real maximum");
}
void testSpectralStreamWriterThreads(void);
void testSpectralStreamWriterThreads(void)
{
    @autoreleasepool {
        sswThreadedByteIdentical();
    }
}

void testSpectralStreamWriter(void)
{
    @autoreleasepool {
        sswStreamedEqualsEager();
        sswZlibAndMemory();
        sswBlockIndex();
        sswBlockIndexAbsentWithoutFdz();
        sswBasePeakFromFloat32Intensity();
    }
}
