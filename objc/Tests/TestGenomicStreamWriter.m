/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOGenomicStreamWriter: the blocks_v1 layout (format-spec 10.12),
 * chromosome cuts, the legacy flag, single-read appends and the default
 * flip in writeMinimalToPath.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSpectralDataset+GenomicWrite.h"
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Genomics/TTIOGenomicBlocks.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOLazyReference.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

extern TTIOWrittenGenomicRun *gbM87Run(NSString *region);
extern id<TTIOStorageGroup> gbMemRoot(NSString *url);

static id<TTIOStorageGroup> gswStudy(NSString *url)
{
    id<TTIOStorageGroup> root = gbMemRoot(url);
    return [root createGroupNamed:@"study" error:NULL];
}

static NSArray *gswIndexRows(id<TTIOStorageGroup> study, NSString *name)
{
    NSError *err = nil;
    id<TTIOStorageGroup> rg = [[study openGroupNamed:@"genomic_runs" error:&err] openGroupNamed:name error:&err];
    id<TTIOStorageDataset> idx = [[rg openGroupNamed:@"blocks" error:&err] openDatasetNamed:@"index" error:&err];
    return [idx readRows:&err];
}

static void gswLayout(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) { PASS(YES, "stream writer: m87 BAM unavailable, skipped"); return; }
    NSString *url = [NSString stringWithFormat:@"memory://gsw-layout-%d", (int)getpid()];
    id<TTIOStorageGroup> study = gswStudy(url);
    NSError *err = nil;
    TTIOGenomicStreamWriterOptions *o = [TTIOGenomicStreamWriterOptions optionsFromRun:run];
    o.blockReads = 3;
    TTIOGenomicStreamWriter *w = [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study runName:@"g" options:o];
    PASS([w appendBatch:run error:&err], "stream writer: appendBatch (%s)", [[err localizedDescription] UTF8String] ?: "");
    PASS([w close:&err], "stream writer: close (%s)", [[err localizedDescription] UTF8String] ?: "");
    PASS(w.readCount == 10, "stream writer: readCount %llu", w.readCount);
    // chr1 5 reads -> 3+2, chr2 2 -> 2, * 3 -> 3
    PASS(w.blockCount == 4, "stream writer: chromosome cuts give 4 blocks (%lu)", (unsigned long)w.blockCount);
    id<TTIOStorageGroup> runs = [study openGroupNamed:@"genomic_runs" error:&err];
    PASS([[[runs attributeValueForName:@"_run_names" error:NULL] description] isEqualToString:@"g"],
         "stream writer: _run_names maintained");
    id<TTIOStorageGroup> rg = [runs openGroupNamed:@"g" error:&err];
    PASS([[[rg attributeValueForName:@"layout" error:NULL] description] isEqualToString:@"blocks_v1"],
         "stream writer: @layout blocks_v1");
    PASS([[[rg attributeValueForName:@"block_policy" error:NULL] description]
             isEqualToString:@"reads=3,bytes=268435456"], "stream writer: @block_policy");
    PASS([[rg attributeValueForName:@"read_count" error:NULL] longLongValue] == 10
         && [[rg attributeValueForName:@"base_count" error:NULL] longLongValue] == 720,
         "stream writer: @read_count/@base_count");
    NSArray *rows = gswIndexRows(study, @"g");
    PASS(rows.count == 4, "stream writer: 4 index rows (%lu)", (unsigned long)rows.count);
    PASS([TTIOGenomicStreamWriter indexFields].count == 19 && [rows[0] count] == 19,
         "stream writer: 19 index columns");
    NSDictionary *r0 = rows[0], *r1 = rows.count > 1 ? rows[1] : nil;
    PASS([r0[@"read_start"] unsignedLongLongValue] == 0 && [r0[@"n_reads"] unsignedIntValue] == 3
         && [r1[@"read_start"] unsignedLongLongValue] == 3 && [r1[@"n_reads"] unsignedIntValue] == 2
         && [r1[@"base_start"] unsignedLongLongValue] == 300,
         "stream writer: read_start/base_start chain");
    unsigned long long off1 = [r1[@"qualities_off"] unsignedLongLongValue];
    PASS(off1 == [r0[@"qualities_len"] unsignedLongLongValue],
         "stream writer: block 1 qualities_off follows block 0 qualities_len");
    PASS([r0[@"qualities_codec"] unsignedIntValue] == TTIOCompressionFqzcompNx16Z
         && [r0[@"cigars_codec"] unsignedIntValue] == TTIOCompressionRansOrder0
         && [r0[@"sequences_codec"] unsignedIntValue] == TTIOCompressionRansOrder1,
         "stream writer: forced codecs in the index");
    NSDictionary *r3 = rows.count > 3 ? rows[3] : nil;
    PASS([r3[@"qualities_codec"] unsignedIntValue] == TTIOCompressionRansOrder0,
         "stream writer: unmapped block with a zero-length read uses RANS_ORDER0 qualities");
    id<TTIOStorageGroup> sc = [rg openGroupNamed:@"signal_channels" error:&err];
    id<TTIOStorageDataset> seq = [[sc openGroupNamed:@"sequences" error:&err] openDatasetNamed:@"data" error:&err];
    PASS(seq != nil && [seq isExtendable], "stream writer: sequences/data extendable");
    unsigned long long seqTotal = 0;
    for (NSDictionary *r in rows) seqTotal += [r[@"sequences_len"] unsignedLongLongValue];
    PASS([seq length] == seqTotal, "stream writer: sequences/data length is the sum of the block lens");
    id<TTIOStorageDataset> q = [sc openDatasetNamed:@"qualities" error:&err];
    PASS([[q attributeValueForName:@"compression" error:NULL] integerValue] == TTIOCompressionFqzcompNx16Z,
         "stream writer: qualities @compression is the first block's codec");
    id<TTIOStorageGroup> idx = [rg openGroupNamed:@"genomic_index" error:&err];
    PASS([[[idx openDatasetNamed:@"lengths" error:&err] readAll:&err] isEqualToData:run.lengthsData]
         && [[[idx openDatasetNamed:@"flags" error:&err] readAll:&err] isEqualToData:run.flagsData]
         && [[[idx openDatasetNamed:@"positions" error:&err] readAll:&err] isEqualToData:run.positionsData],
         "stream writer: index arrays equal the run's");
    PASS(![idx hasChildNamed:@"offsets"], "stream writer: no offsets on disk");
    NSArray *names = [[idx openDatasetNamed:@"chromosome_names" error:&err] readRows:&err];
    PASS(names.count == 3 && [[names[0][@"name"] description] isEqualToString:@"chr1"],
         "stream writer: chromosome_names in first-seen order (%lu)", (unsigned long)names.count);
    NSArray *mateNames = [[[sc openGroupNamed:@"mate_info" error:&err] openDatasetNamed:@"chrom_names" error:&err] readRows:&err];
    PASS(mateNames.count == names.count, "stream writer: mate_info/chrom_names shares the map");
    [TTIOMemoryProvider discardStore:url];
}

static void gswLegacy(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSString *url = [NSString stringWithFormat:@"memory://gsw-legacy-%d", (int)getpid()];
    id<TTIOStorageGroup> study = gswStudy(url);
    NSError *err = nil;
    TTIOGenomicStreamWriterOptions *o = [TTIOGenomicStreamWriterOptions optionsFromRun:run];
    o.optLegacyWholeChannel = YES;
    TTIOGenomicStreamWriter *w = [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study runName:@"g" options:o];
    PASS([w appendBatch:run error:&err] && [w close:&err], "stream writer: legacy write");
    id<TTIOStorageGroup> rg = [[study openGroupNamed:@"genomic_runs" error:&err] openGroupNamed:@"g" error:&err];
    PASS(rg != nil && ![rg hasAttributeNamed:@"layout"] && ![rg hasChildNamed:@"blocks"],
         "stream writer: legacy flag gives the whole-channel layout");
    PASS([[[rg openGroupNamed:@"signal_channels" error:&err] openDatasetNamed:@"cigars" error:&err] compoundFields].count == 1,
         "stream writer: legacy layout keeps the compound cigars");
    [TTIOMemoryProvider discardStore:url];
}

static void gswSingleReadEqualsBatch(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSError *err = nil;
    NSString *urlA = [NSString stringWithFormat:@"memory://gsw-a-%d", (int)getpid()];
    NSString *urlB = [NSString stringWithFormat:@"memory://gsw-b-%d", (int)getpid()];
    id<TTIOStorageGroup> sa = gswStudy(urlA), sb = gswStudy(urlB);
    TTIOGenomicStreamWriterOptions *o = [TTIOGenomicStreamWriterOptions optionsFromRun:run];
    o.blockReads = 4;
    TTIOGenomicStreamWriter *wa = [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:sa runName:@"g" options:o];
    TTIOGenomicStreamWriter *wb = [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:sb runName:@"g" options:o];
    BOOL ok = [wa appendBatch:run error:&err] && [wa close:&err];
    const uint64_t *offs = (const uint64_t *)run.offsetsData.bytes;
    const uint32_t *lens = (const uint32_t *)run.lengthsData.bytes;
    const int64_t *pos = (const int64_t *)run.positionsData.bytes;
    const uint8_t *mapq = (const uint8_t *)run.mappingQualitiesData.bytes;
    const uint32_t *flags = (const uint32_t *)run.flagsData.bytes;
    const int64_t *mpos = (const int64_t *)run.matePositionsData.bytes;
    const int32_t *tlen = (const int32_t *)run.templateLengthsData.bytes;
    for (NSUInteger i = 0; i < run.readCount && ok; i++) {
        NSData *seq = [run.sequencesData subdataWithRange:NSMakeRange((NSUInteger)offs[i], lens[i])];
        NSData *qual = [run.qualitiesData subdataWithRange:NSMakeRange((NSUInteger)offs[i], lens[i])];
        TTIOAlignedRead *r = [[TTIOAlignedRead alloc]
            initWithReadName:run.readNames[i] chromosome:run.chromosomes[i] position:pos[i]
              mappingQuality:mapq[i] cigar:run.cigars[i]
                    sequence:[[NSString alloc] initWithData:seq encoding:NSASCIIStringEncoding]
                   qualities:qual flags:flags[i] mateChromosome:run.mateChromosomes[i]
                matePosition:mpos[i] templateLength:tlen[i]];
        ok = [wb appendRead:r error:&err];
    }
    ok = ok && [wb close:&err];
    PASS(ok, "stream writer: per-read appends (%s)", [[err localizedDescription] UTF8String] ?: "");
    NSArray *ra = gswIndexRows(sa, @"g"), *rb = gswIndexRows(sb, @"g");
    PASS(ra.count == rb.count && ra.count == 4, "stream writer: same block count (%lu vs %lu)",
         (unsigned long)ra.count, (unsigned long)rb.count);
    BOOL same = ra.count == rb.count;
    for (NSUInteger i = 0; i < ra.count && same; i++) {
        for (TTIOCompoundField *f in [TTIOGenomicStreamWriter indexFields]) {
            if (![[ra[i][f.name] description] isEqualToString:[rb[i][f.name] description]]) { same = NO; break; }
        }
    }
    PASS(same, "stream writer: identical block index");
    id<TTIOStorageGroup> sca = [[[sa openGroupNamed:@"genomic_runs" error:&err] openGroupNamed:@"g" error:&err] openGroupNamed:@"signal_channels" error:&err];
    id<TTIOStorageGroup> scb = [[[sb openGroupNamed:@"genomic_runs" error:&err] openGroupNamed:@"g" error:&err] openGroupNamed:@"signal_channels" error:&err];
    BOOL bytesSame = YES;
    for (NSString *ch in @[@"qualities", @"read_names", @"cigars"]) {
        NSData *a = [[sca openDatasetNamed:ch error:&err] readAll:&err];
        NSData *b = [[scb openDatasetNamed:ch error:&err] readAll:&err];
        if (![a isEqualToData:b]) bytesSame = NO;
    }
    NSData *qa = [[[sca openGroupNamed:@"sequences" error:&err] openDatasetNamed:@"data" error:&err] readAll:&err];
    NSData *qb = [[[scb openGroupNamed:@"sequences" error:&err] openDatasetNamed:@"data" error:&err] readAll:&err];
    if (![qa isEqualToData:qb]) bytesSame = NO;
    PASS(bytesSame, "stream writer: identical channel bytes");
    [TTIOMemoryProvider discardStore:urlA];
    [TTIOMemoryProvider discardStore:urlB];
}

static void gswWriteMinimalDefault(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSError *err = nil;
    NSString *path = [NSString stringWithFormat:@"/tmp/gsw-default-%d.tio", (int)getpid()];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path title:@"t" isaInvestigationId:@"i"
                                              msRuns:@{} genomicRuns:@{@"genomic_0001": run}
                                     identifications:nil quantifications:nil provenanceRecords:nil
                                               error:&err];
    PASS(ok, "stream writer: writeMinimalToPath default (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOHDF5Group *rg = [[[f rootGroup] openGroupNamed:@"study" error:&err] openGroupNamed:@"genomic_runs" error:&err];
    rg = [rg openGroupNamed:@"genomic_0001" error:&err];
    PASS(rg != nil && [[rg stringAttributeNamed:@"layout" error:NULL] isEqualToString:@"blocks_v1"]
         && [rg hasChildNamed:@"blocks"],
         "stream writer: writeMinimalToPath writes blocks_v1 by default");
    [f close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    TTIOWrittenGenomicRun *legacy = [run copyWithOptLegacyWholeChannel:YES];
    ok = [TTIOSpectralDataset writeMinimalToPath:path title:@"t" isaInvestigationId:@"i"
                                          msRuns:@{} genomicRuns:@{@"genomic_0001": legacy}
                                 identifications:nil quantifications:nil provenanceRecords:nil
                                           error:&err];
    f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    rg = [[[[f rootGroup] openGroupNamed:@"study" error:&err] openGroupNamed:@"genomic_runs" error:&err]
          openGroupNamed:@"genomic_0001" error:&err];
    PASS(ok && rg != nil && ![rg hasAttributeNamed:@"layout"] && ![rg hasChildNamed:@"blocks"],
         "stream writer: optLegacyWholeChannel keeps the v1.8 layout in writeMinimalToPath");
    [f close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    // Storage-path writeMinimal (memory://) takes the same default.
    NSString *url = [NSString stringWithFormat:@"memory://gsw-wm-%d", (int)getpid()];
    [TTIOMemoryProvider discardStore:url];
    ok = [TTIOSpectralDataset writeMinimalToPath:url title:@"t" isaInvestigationId:@"i"
                                          msRuns:@{} genomicRuns:@{@"genomic_0001": run}
                                 identifications:nil quantifications:nil provenanceRecords:nil
                                           error:&err];
    PASS(ok, "stream writer: memory:// writeMinimal (%s)", [[err localizedDescription] UTF8String] ?: "");
    id<TTIOStorageProvider> p = [[TTIOProviderRegistry sharedRegistry] openURL:url mode:TTIOStorageOpenModeRead provider:@"memory" error:&err];
    id<TTIOStorageGroup> mrg = [[[[p rootGroupWithError:&err] openGroupNamed:@"study" error:&err]
                                 openGroupNamed:@"genomic_runs" error:&err] openGroupNamed:@"genomic_0001" error:&err];
    PASS([[[mrg attributeValueForName:@"layout" error:NULL] description] isEqualToString:@"blocks_v1"],
         "stream writer: memory:// writeMinimal writes blocks_v1");
    [TTIOMemoryProvider discardStore:url];
}

static void gswLazyReference(void)
{
    NSError *err = nil;
    NSString *fa = [NSString stringWithFormat:@"/tmp/gsw-ref-%d.fa", (int)getpid()];
    NSString *text = @">chrA desc\nACGTACGTAC\nGTAC\n>chrB\nNNNNACGT\nACG\n>chrE\n";
    [text writeToFile:fa atomically:YES encoding:NSASCIIStringEncoding error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[fa stringByAppendingString:@".fai"] error:NULL];
    TTIOLazyReference *ref = [[TTIOLazyReference alloc] initWithFastaPath:fa error:&err];
    PASS(ref != nil, "lazy reference: opens without a .fai (%s)", [[err localizedDescription] UTF8String] ?: "");
    if (!ref) return;
    PASS([[NSFileManager defaultManager] fileExistsAtPath:[fa stringByAppendingString:@".fai"]],
         "lazy reference: writes the .fai");
    NSArray *expectNames = @[@"chrA", @"chrB", @"chrE"];
    PASS(ref.count == 3 && [ref.chromosomeNames isEqualToArray:expectNames],
         "lazy reference: three entries in FASTA order");
    PASS([ref lengthOf:@"chrA"] == 14 && [ref lengthOf:@"chrB"] == 11 && [ref lengthOf:@"chrE"] == 0,
         "lazy reference: lengths from the index");
    NSData *a = ref[@"chrA"];
    PASS([a isEqualToData:[@"ACGTACGTACGTAC" dataUsingEncoding:NSASCIIStringEncoding]],
         "lazy reference: chrA bytes without newlines");
    PASS([ref[@"chrB"] isEqualToData:[@"NNNNACGTACG" dataUsingEncoding:NSASCIIStringEncoding]],
         "lazy reference: chrB across uneven lines");
    PASS(ref[@"chrE"].length == 0 && ref[@"nope"] == nil, "lazy reference: empty and unknown");
    PASS([[ref copy] isKindOfClass:[TTIOLazyReference class]], "lazy reference: copy is the same object");
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *k in ref) [keys addObject:k];
    PASS(keys.count == 3, "lazy reference: fast enumeration over keys");
    // A second open reads the .fai written by the first.
    TTIOLazyReference *ref2 = [[TTIOLazyReference alloc] initWithFastaPath:fa error:&err];
    PASS(ref2 != nil && [ref2[@"chrA"] isEqualToData:a], "lazy reference: reopens from the .fai");
    [[NSFileManager defaultManager] removeItemAtPath:fa error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[fa stringByAppendingString:@".fai"] error:NULL];
}

void testGenomicStreamWriter(void)
{
    @autoreleasepool {
        gswLayout();
        gswLegacy();
        gswSingleReadEqualsBatch();
        gswWriteMinimalDefault();
        gswLazyReference();
    }
}
