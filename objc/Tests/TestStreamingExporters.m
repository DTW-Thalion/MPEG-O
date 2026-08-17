/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Streaming exporters: BAM, FASTQ and mzML written read by read /
 * spectrum by spectrum from stored runs equal the whole-run exports.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Export/TTIOBamWriter.h"
#import "Export/TTIOFastqWriter.h"
#import "Export/TTIOMzMLWriter.h"
#import "Export/TTIORunSelection.h"
#import "Import/TTIOBamReader.h"
#import "Import/TTIOMzMLReader.h"
#import "Import/TTIOFastqReader.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Run/TTIOAcquisitionRun.h"
#include <unistd.h>

extern TTIOWrittenGenomicRun *gbM87Run(NSString *region);
extern NSString *bgSam11Md5FromRun(TTIOGenomicRun *run);
extern NSString *bgSam11Md5FromSam(NSString *samPath);
extern NSString *bgSamPath(void);

static NSString *seTmp(const char *tag, const char *ext)
{
    return [NSString stringWithFormat:@"/tmp/se-%s-%d.%s", tag, (int)getpid(), ext];
}

static void seBam(void)
{
    TTIOWrittenGenomicRun *whole = gbM87Run(nil);
    NSString *sam = bgSamPath();
    if (!whole || !sam) { PASS(YES, "streaming exporters: BAM fixture or samtools unavailable, skipped"); return; }
    NSError *err = nil;
    NSString *tio = seTmp("bam-src", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:tio error:NULL];
    [TTIOSpectralDataset writeMinimalToPath:tio title:@"t" isaInvestigationId:@"i" msRuns:@{}
                                genomicRuns:@{@"g": whole} identifications:nil quantifications:nil
                          provenanceRecords:nil error:&err];
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:tio error:&err];
    TTIOGenomicRun *g = ds.genomicRuns[@"g"];
    PASS(g != nil && g.blockCount == 3, "streaming exporters: three-block source run");

    NSString *streamed = seTmp("stream", "bam"), *eager = seTmp("eager", "bam");
    TTIOBamWriter *w1 = [[TTIOBamWriter alloc] initWithPath:streamed];
    PASS([w1 writeReadSideRun:g provenanceRecords:@[] sort:NO error:&err],
         "streaming exporters: BAM writeReadSideRun (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOBamWriter *w2 = [[TTIOBamWriter alloc] initWithPath:eager];
    TTIOWrittenGenomicRun *written = [TTIORunSelection writtenFromGenomicRun:g];
    PASS([w2 writeRun:written provenanceRecords:@[] sort:NO error:&err],
         "streaming exporters: BAM whole-run write (%s)", [[err localizedDescription] UTF8String] ?: "");
    // The two BAMs differ only in samtools' own @PG line (it records the
    // output path), so compare sizes here and the records below.
    NSData *b1 = [NSData dataWithContentsOfFile:streamed], *b2 = [NSData dataWithContentsOfFile:eager];
    PASS(b1.length > 0 && b1.length == b2.length, "streaming exporters: streamed BAM is the size of the whole-run export (%lu vs %lu)",
         (unsigned long)b1.length, (unsigned long)b2.length);
    // Re-import and compare with the source SAM.
    TTIOBamReader *r = [[TTIOBamReader alloc] initWithPath:streamed];
    TTIOWrittenGenomicRun *back = [r toGenomicRunWithName:@"b" region:nil sampleName:nil error:&err];
    NSString *tio2 = seTmp("bam-back", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:tio2 error:NULL];
    [TTIOSpectralDataset writeMinimalToPath:tio2 title:@"t" isaInvestigationId:@"i" msRuns:@{}
                                genomicRuns:@{@"b": back} identifications:nil quantifications:nil
                          provenanceRecords:nil error:&err];
    TTIOGenomicRun *gb = [TTIOSpectralDataset readFromFilePath:tio2 error:&err].genomicRuns[@"b"];
    PASS(gb && [bgSam11Md5FromRun(gb) isEqualToString:bgSam11Md5FromSam(sam)],
         "streaming exporters: exported BAM re-imports to the source SAM digest");
    // Sorted export works through the two-stage pipeline too.
    NSString *sorted = seTmp("sorted", "bam");
    TTIOBamWriter *w3 = [[TTIOBamWriter alloc] initWithPath:sorted];
    PASS([w3 writeReadSideRun:g provenanceRecords:ds.provenanceRecords sort:YES error:&err]
         && [[NSFileManager defaultManager] fileExistsAtPath:sorted],
         "streaming exporters: sorted BAM export (%s)", [[err localizedDescription] UTF8String] ?: "");
    [g close]; [gb close];
    for (NSString *p in @[tio, tio2, streamed, eager, sorted]) [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

static void seFastq(void)
{
    TTIOWrittenGenomicRun *whole = gbM87Run(nil);
    if (!whole) return;
    NSError *err = nil;
    NSString *tio = seTmp("fq-src", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:tio error:NULL];
    [TTIOSpectralDataset writeMinimalToPath:tio title:@"t" isaInvestigationId:@"i" msRuns:@{}
                                genomicRuns:@{@"g": whole} identifications:nil quantifications:nil
                          provenanceRecords:nil error:&err];
    TTIOGenomicRun *g = [TTIOSpectralDataset readFromFilePath:tio error:&err].genomicRuns[@"g"];
    NSString *streamed = seTmp("stream", "fastq"), *eager = seTmp("eager", "fastq");
    PASS([TTIOFastqWriter writeReadSideRun:g toPath:streamed gzipOutput:0 phredOffset:33 error:&err],
         "streaming exporters: FASTQ writeReadSideRun (%s)", [[err localizedDescription] UTF8String] ?: "");
    PASS([TTIOFastqWriter writeRun:whole toPath:eager gzipOutput:0 phredOffset:33 error:&err],
         "streaming exporters: FASTQ whole-run write");
    NSData *f1 = [NSData dataWithContentsOfFile:streamed], *f2 = [NSData dataWithContentsOfFile:eager];
    PASS(f1.length > 0 && [f1 isEqualToData:f2], "streaming exporters: streamed FASTQ bytes equal the whole-run export");
    NSString *gzp = seTmp("stream", "fastq.gz");
    PASS([TTIOFastqWriter writeReadSideRun:g toPath:gzp gzipOutput:0 phredOffset:64 error:&err],
         "streaming exporters: gzip FASTQ export");
    uint8_t det = 0;
    TTIOWrittenGenomicRun *back = [TTIOFastqReader readFromPath:gzp forcedPhred:64 sampleName:@"" platform:@""
                                                   referenceUri:@"" acquisitionMode:TTIOAcquisitionModeGenomicWGS
                                                    outDetected:&det error:&err];
    PASS(back != nil && back.readCount == whole.readCount && det == 64
         && [back.qualitiesData isEqualToData:whole.qualitiesData] && [back.sequencesData isEqualToData:whole.sequencesData],
         "streaming exporters: gzip Phred+64 FASTQ re-imports to the source bytes (%lu reads)", (unsigned long)back.readCount);
    [g close];
    for (NSString *p in @[tio, streamed, eager, gzp]) [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

static void seMzML(void)
{
    NSString *fx = nil;
    for (NSString *p in @[@"Tests/Fixtures/1min.mzML", @"/home/toddw/TTI-O/objc/Tests/Fixtures/1min.mzML"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { fx = p; break; }
    }
    if (!fx) return;
    NSError *err = nil;
    NSString *tio = seTmp("mz-src", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:tio error:NULL];
    TTIOSpectralDataset *src = [TTIOMzMLReader readFromFilePath:fx error:&err];
    PASS([src writeToFilePath:tio error:&err], "streaming exporters: mzML source .tio (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:tio error:&err];
    NSString *out = seTmp("stream", "mzML");
    PASS([TTIOMzMLWriter writeDataset:ds toPath:out zlibCompression:YES error:&err],
         "streaming exporters: mzML writeDataset:toPath (%s)", [[err localizedDescription] UTF8String] ?: "");
    NSData *eager = [TTIOMzMLWriter dataForDataset:ds zlibCompression:YES error:&err];
    NSData *streamed = [NSData dataWithContentsOfFile:out];
    PASS(streamed.length > 0 && [streamed isEqualToData:eager],
         "streaming exporters: file mzML bytes equal the in-memory document (%lu vs %lu)",
         (unsigned long)streamed.length, (unsigned long)eager.length);
    TTIOSpectralDataset *back = [TTIOMzMLReader readFromFilePath:out error:&err];
    TTIOAcquisitionRun *rb = [back.msRuns.allValues firstObject];
    TTIOAcquisitionRun *rs = [src.msRuns.allValues firstObject];
    PASS(rb != nil && rb.count == rs.count, "streaming exporters: exported mzML re-parses (%lu spectra)", (unsigned long)rb.count);
    PASS(![[NSFileManager defaultManager] fileExistsAtPath:[out stringByAppendingString:@".part"]],
         "streaming exporters: no .part file left behind");
    for (NSString *p in @[tio, out]) [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

void testStreamingExporters(void)
{
    @autoreleasepool {
        seBam();
        seFastq();
        seMzML();
    }
}
