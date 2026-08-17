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
#import "Run/TTIOSpectralStreamWriter.h"
#import "Run/TTIOWrittenSpectralBatch.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "Codecs/TTIOFloatDeltaZstd.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOStorageProtocols.h"
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

void testSpectralStreamWriter(void)
{
    @autoreleasepool {
        sswStreamedEqualsEager();
        sswZlibAndMemory();
    }
}
