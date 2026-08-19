/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Streaming importers: BAM batches through the samtools pipe, FASTQ
 * batches, the mzML producer thread, and TTIOImportedDataset writing
 * the streams after the static content.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Import/TTIOBamReader.h"
#import "Import/TTIOFastqReader.h"
#import "Import/TTIOMzMLReader.h"
#import "Import/TTIOImportedDataset.h"
#import "Import/TTIOImporterRegistry.h"
#import "Import/TTIOGenomicStreamSource.h"
#import "Import/TTIOSpectralStreamSource.h"
#import "Genomics/TTIOGenomicBlocks.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOFeatureFlags.h"
#include <unistd.h>
#include <zlib.h>

extern TTIOWrittenGenomicRun *gbM87Run(NSString *region);
extern NSString *bgSam11Md5FromRun(TTIOGenomicRun *run);

static NSString *siFixture(NSString *rel)
{
    for (NSString *p in @[[@"Tests/Fixtures/" stringByAppendingString:rel],
                          [@"Fixtures/" stringByAppendingString:rel],
                          [@"/home/toddw/TTI-O/objc/Tests/Fixtures/" stringByAppendingString:rel]]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

static NSString *siTmp(const char *tag, const char *ext)
{
    return [NSString stringWithFormat:@"/tmp/si-%s-%d.%s", tag, (int)getpid(), ext];
}

static BOOL siSameRun(TTIOWrittenGenomicRun *a, TTIOWrittenGenomicRun *b)
{
    return a.readCount == b.readCount
        && [a.offsetsData isEqualToData:b.offsetsData] && [a.lengthsData isEqualToData:b.lengthsData]
        && [a.sequencesData isEqualToData:b.sequencesData] && [a.qualitiesData isEqualToData:b.qualitiesData]
        && [a.positionsData isEqualToData:b.positionsData] && [a.flagsData isEqualToData:b.flagsData]
        && [a.mappingQualitiesData isEqualToData:b.mappingQualitiesData]
        && [a.matePositionsData isEqualToData:b.matePositionsData]
        && [a.templateLengthsData isEqualToData:b.templateLengthsData]
        && [a.cigars isEqualToArray:b.cigars] && [a.readNames isEqualToArray:b.readNames]
        && [a.mateChromosomes isEqualToArray:b.mateChromosomes] && [a.chromosomes isEqualToArray:b.chromosomes]
        && [a.referenceUri isEqualToString:b.referenceUri] && [a.sampleName isEqualToString:b.sampleName]
        && [a.platform isEqualToString:b.platform];
}

static void siBamBatches(void)
{
    NSString *bam = siFixture(@"genomic/m87_test.bam");
    TTIOWrittenGenomicRun *whole = gbM87Run(nil);
    if (!bam || !whole) { PASS(YES, "streaming importers: BAM fixture or samtools unavailable, skipped"); return; }
    NSError *err = nil;
    TTIOBamReader *r = [[TTIOBamReader alloc] initWithPath:bam];
    NSMutableArray *batches = [NSMutableArray array];
    BOOL ok = [r iterBatchesWithRegion:nil sampleName:nil batchReads:3 progress:nil error:&err
                            usingBlock:^BOOL(TTIOWrittenGenomicRun *batch, NSError **e) {
        (void)e;
        [batches addObject:batch];
        return YES;
    }];
    PASS(ok, "streaming importers: BAM iterBatches (%s)", [[err localizedDescription] UTF8String] ?: "");
    PASS(batches.count == 4, "streaming importers: 10 reads in batches of 3 give 4 batches (%lu)",
         (unsigned long)batches.count);
    NSUInteger n0 = batches.count ? [batches[0] readCount] : 0;
    PASS(n0 == 3, "streaming importers: first BAM batch has 3 reads");
    TTIOWrittenGenomicRun *cat = [TTIOGenomicBlocks concatRuns:batches];
    PASS(siSameRun(cat, whole), "streaming importers: BAM batches concatenate to the whole run");
    PASS([[batches.firstObject referenceUri] isEqualToString:whole.referenceUri]
         && [[batches.lastObject platform] isEqualToString:whole.platform],
         "streaming importers: every BAM batch carries the header metadata");
    PASS(r.provenanceRecords.count > 0, "streaming importers: @PG provenance collected while streaming");
    // Early stop.
    __block NSUInteger seen = 0;
    ok = [r iterBatchesWithRegion:nil sampleName:nil batchReads:2 progress:nil error:&err
                       usingBlock:^BOOL(TTIOWrittenGenomicRun *batch, NSError **e) {
        (void)batch;
        seen++;
        if (seen == 2) {
            *e = [NSError errorWithDomain:@"test" code:7 userInfo:nil];
            return NO;
        }
        return YES;
    }];
    PASS(!ok && seen == 2 && err.code == 7, "streaming importers: a consumer stop ends the walk with its error");
    // Region.
    NSMutableArray *chr1 = [NSMutableArray array];
    ok = [r iterBatchesWithRegion:@"chr1" sampleName:@"S" batchReads:100 progress:nil error:&err
                       usingBlock:^BOOL(TTIOWrittenGenomicRun *batch, NSError **e) {
        (void)e; [chr1 addObject:batch]; return YES;
    }];
    PASS(ok && chr1.count == 1 && [chr1[0] readCount] == 5 && [[chr1[0] sampleName] isEqualToString:@"S"],
         "streaming importers: BAM region batch with a sample override");
}

static void siBamStreamWrite(void)
{
    NSString *bam = siFixture(@"genomic/m87_test.bam");
    TTIOWrittenGenomicRun *whole = gbM87Run(nil);
    if (!bam || !whole) return;
    NSError *err = nil;
    NSString *out = siTmp("bam", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    TTIOBamReader *r = [[TTIOBamReader alloc] initWithPath:bam];
    TTIOGenomicStreamSource *src = [[r streamWithName:@"g" region:nil sampleName:nil referenceFasta:nil
                                       embedReference:NO batchReads:4 progress:nil]
                                    sourceWithBlockReads:@3 blockBytes:nil legacy:NO];
    TTIOImportedDataset *d = [[TTIOImportedDataset alloc] init];
    d.title = @"stream";
    d.genomicStreams[@"g"] = src;
    PASS([d writeToPath:out error:&err], "streaming importers: BAM stream writes (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *g = ds.genomicRuns[@"g"];
    PASS(g != nil && [g.layout isEqualToString:@"blocks_v1"] && g.readCount == 10 && g.blockCount == 4,
         "streaming importers: streamed BAM run is blocks_v1 with 4 blocks (%lu)", (unsigned long)g.blockCount);
    // Same reads as the eager import written the default way.
    NSString *ref = siTmp("bam-eager", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:ref error:NULL];
    [TTIOSpectralDataset writeMinimalToPath:ref title:@"t" isaInvestigationId:@"i" msRuns:@{}
                                genomicRuns:@{@"g": whole} identifications:nil quantifications:nil
                          provenanceRecords:nil error:&err];
    TTIOGenomicRun *ge = [TTIOSpectralDataset readFromFilePath:ref error:&err].genomicRuns[@"g"];
    PASS(ge && [bgSam11Md5FromRun(g) isEqualToString:bgSam11Md5FromRun(ge)],
         "streaming importers: streamed BAM digest equals the eager import");
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:out error:NULL];
    PASS([TTIOFeatureFlags root:[f rootGroup] supportsFeature:[TTIOFeatureFlags featureOptGenomic]],
         "streaming importers: opt_genomic feature flag set for a streamed genomic run");
    [f close];
    [g close]; [ge close];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:ref error:NULL];

    // Through the importer registry (the TtioEncode path) with extras.
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    BOOL ok = [TTIOImporterRegistry encodeFormat:@"bam" inputs:@[bam] output:out
                                         options:@{@"name": @"reg", @"block_reads": @"3", @"batch_reads": @"4"}
                                           error:&err];
    PASS(ok, "streaming importers: registry bam encode (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOGenomicRun *gr = [TTIOSpectralDataset readFromFilePath:out error:&err].genomicRuns[@"reg"];
    PASS(gr != nil && gr.blockCount == 4 && gr.readCount == 10, "streaming importers: registry run honours block_reads");
    [gr close];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    ok = [TTIOImporterRegistry encodeFormat:@"bam" inputs:@[bam] output:out
                                    options:@{@"name": @"leg", @"legacy_whole_channel": @"true"} error:&err];
    TTIOGenomicRun *gl = [TTIOSpectralDataset readFromFilePath:out error:&err].genomicRuns[@"leg"];
    PASS(ok && gl != nil && [gl.layout isEqualToString:@"whole"], "streaming importers: legacy_whole_channel extra");
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
}

static void siFastq(void)
{
    NSError *err = nil;
    NSString *fq = siTmp("reads", "fastq");
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < 7; i++) {
        [text appendFormat:@"@read%d extra\nACGTAC%d\n+\n#II5#I%c\n", i, i % 10, '5' + i];
    }
    [text writeToFile:fq atomically:YES encoding:NSASCIIStringEncoding error:NULL];
    uint8_t detected = 0;
    TTIOWrittenGenomicRun *whole = [TTIOFastqReader readFromPath:fq forcedPhred:0 sampleName:@"s" platform:@""
                                                    referenceUri:@"" acquisitionMode:TTIOAcquisitionModeGenomicWGS
                                                     outDetected:&detected error:&err];
    PASS(whole != nil && whole.readCount == 7 && detected == 33, "streaming importers: FASTQ eager read (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    NSMutableArray *batches = [NSMutableArray array];
    uint8_t det2 = 0;
    BOOL ok = [TTIOFastqReader iterBatchesFromPath:fq forcedPhred:0 sampleName:@"s" platform:@"" referenceUri:@""
                                    acquisitionMode:TTIOAcquisitionModeGenomicWGS batchReads:3 outDetected:&det2
                                           progress:nil error:&err
                                         usingBlock:^BOOL(TTIOWrittenGenomicRun *b, NSError **e) {
        (void)e; [batches addObject:b]; return YES;
    }];
    PASS(ok && batches.count == 3 && det2 == 33, "streaming importers: FASTQ batches of 3 (%lu, phred %u)",
         (unsigned long)batches.count, (unsigned)det2);
    PASS(siSameRun([TTIOGenomicBlocks concatRuns:batches], whole), "streaming importers: FASTQ batches concatenate to the eager run");
    NSString *out = siTmp("fq", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    TTIOImportedDataset *d = [[TTIOImportedDataset alloc] init];
    d.genomicStreams[@"fq"] = [TTIOFastqReader streamFromPath:fq name:@"fq" sampleName:@"s" batchReads:2 progress:nil];
    PASS([d writeToPath:out error:&err], "streaming importers: FASTQ stream writes (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOGenomicRun *g = [TTIOSpectralDataset readFromFilePath:out error:&err].genomicRuns[@"fq"];
    PASS(g != nil && g.readCount == 7 && [g.layout isEqualToString:@"blocks_v1"],
         "streaming importers: streamed FASTQ run reads back (%lu)", (unsigned long)g.readCount);
    TTIOAlignedRead *r6 = [g readAtIndex:6 error:&err];
    PASS(r6 && [r6.readName isEqualToString:@"read6"] && [r6.sequence isEqualToString:@"ACGTAC6"],
         "streaming importers: last FASTQ read intact");
    [g close];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:fq error:NULL];
}

static void siFastqBatchBytes(void)
{
    // 100 reads x 1 MiB: an 8 MiB byte limit (seq + qual = 2 MiB per
    // read) cuts batches at 4 reads whatever batchReads says.
    NSString *fq = siTmp("bb", "fastq");
    NSMutableData *chunk = [NSMutableData dataWithLength:1 << 20];
    memset(chunk.mutableBytes, 'A', chunk.length);
    NSMutableData *qual = [NSMutableData dataWithLength:1 << 20];
    memset(qual.mutableBytes, 'I', qual.length);
    NSMutableData *body = [NSMutableData data];
    for (int i = 0; i < 100; i++) {
        [body appendData:[[NSString stringWithFormat:@"@r%d\n", i] dataUsingEncoding:NSASCIIStringEncoding]];
        [body appendData:chunk];
        [body appendData:[@"\n+\n" dataUsingEncoding:NSASCIIStringEncoding]];
        [body appendData:qual];
        [body appendData:[@"\n" dataUsingEncoding:NSASCIIStringEncoding]];
    }
    [body writeToFile:fq atomically:YES];
    NSError *err = nil;
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    BOOL ok = [TTIOFastqReader iterBatchesFromPath:fq forcedPhred:0 sampleName:@"s" platform:@""
                                      referenceUri:@"" acquisitionMode:TTIOAcquisitionModeGenomicWGS
                                        batchReads:1000000 batchBytes:(8ull << 20)
                                       outDetected:NULL progress:nil error:&err
                                        usingBlock:^BOOL(TTIOWrittenGenomicRun *b, NSError **e) {
        (void)e; [sizes addObject:@(b.readCount)]; return YES;
    }];
    unsigned long long total = 0;
    NSUInteger maxBatch = 0;
    for (NSNumber *n in sizes) { total += n.unsignedLongLongValue; if (n.unsignedIntegerValue > maxBatch) maxBatch = n.unsignedIntegerValue; }
    PASS(ok && total == 100 && sizes.count == 25 && maxBatch == 4,
         "streaming importers: batchBytes cuts at 4 reads (%lu batches, max %lu, %s)",
         (unsigned long)sizes.count, (unsigned long)maxBatch,
         [[err localizedDescription] UTF8String] ?: "");
    [[NSFileManager defaultManager] removeItemAtPath:fq error:NULL];
}

extern NSString *bgSam11Md5FromRun(TTIOGenomicRun *run);

static void siFastqParallelIdentity(void)
{
    // A gzip FASTQ through the parallel pipeline equals the serial
    // producer's genomic bytes exactly.
    NSString *fq = siTmp("par", "fastq.gz");
    gzFile gz = gzopen([fq fileSystemRepresentation], "wb");
    unsigned int rs = 12345;
    for (int i = 0; i < 20000; i++) {
        char seq[4097], qual[4097];
        for (int j = 0; j < 4096; j++) {
            rs = rs * 1103515245u + 12345u;
            seq[j] = "ACGT"[(rs >> 16) & 3];
            qual[j] = (char)(33 + ((rs >> 18) & 31));
        }
        seq[4096] = qual[4096] = 0;
        gzprintf(gz, "@r%d desc\n", i);
        gzwrite(gz, seq, 4096); gzwrite(gz, "\n+\n", 3);
        gzwrite(gz, qual, 4096); gzwrite(gz, "\n", 1);
    }
    gzclose(gz);
    NSError *err = nil;
    NSString *outA = siTmp("par-a", "tio"), *outB = siTmp("par-b", "tio");
    // Parallel (default threads) with small batches so many slots run.
    TTIOImportedDataset *da = [[TTIOImportedDataset alloc] init];
    da.genomicStreams[@"g"] = [TTIOFastqReader streamFromPath:fq name:@"g" sampleName:@"s"
                                                   batchReads:0 batchBytes:(4ull << 20) progress:nil];
    PASS([da writeToPath:outA error:&err], "parallel fastq: pipeline write (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    // Serial.
    setenv("TTIO_THREADS", "1", 1);
    TTIOImportedDataset *db = [[TTIOImportedDataset alloc] init];
    db.genomicStreams[@"g"] = [TTIOFastqReader streamFromPath:fq name:@"g" sampleName:@"s"
                                                   batchReads:0 batchBytes:(4ull << 20) progress:nil];
    BOOL okB = [db writeToPath:outB error:&err];
    unsetenv("TTIO_THREADS");
    PASS(okB, "parallel fastq: serial write (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOGenomicRun *ga = [TTIOSpectralDataset readFromFilePath:outA error:&err].genomicRuns[@"g"];
    TTIOGenomicRun *gb = [TTIOSpectralDataset readFromFilePath:outB error:&err].genomicRuns[@"g"];
    PASS(ga.readCount == 20000 && gb.readCount == 20000,
         "parallel fastq: both runs hold 20000 reads (%llu, %llu)",
         ga.readCount, gb.readCount);
    BOOL same = YES;
    NSUInteger idxs[6] = {0, 1, 9999, 10000, 19998, 19999};
    for (int k = 0; k < 6 && same; k++) {
        TTIOAlignedRead *ra = [ga readAtIndex:idxs[k] error:&err];
        TTIOAlignedRead *rb = [gb readAtIndex:idxs[k] error:&err];
        same = ra && rb && [ra.readName isEqualToString:rb.readName]
            && [ra.sequence isEqualToString:rb.sequence]
            && [ra.qualities isEqualToData:rb.qualities];
    }
    PASS(same, "parallel fastq: spot reads identical");
    NSString *md5a = bgSam11Md5FromRun(ga), *md5b = bgSam11Md5FromRun(gb);
    PASS(md5a != nil && [md5a isEqualToString:md5b],
         "parallel fastq: full-run digest identical (%s)", [md5a UTF8String] ?: "");
    [ga close]; [gb close];
    [[NSFileManager defaultManager] removeItemAtPath:fq error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:outA error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:outB error:NULL];
}

static void siWritePlainFixture(NSString *path, int nReads, int bigEvery, int bigLen)
{
    FILE *fp = fopen([path fileSystemRepresentation], "wb");
    unsigned int rs = 777;
    char *big = malloc((size_t)bigLen + 1);
    for (int i = 0; i < nReads; i++) {
        int len = (bigEvery > 0 && (i % bigEvery) == 0) ? bigLen : 120;
        fprintf(fp, "@s%d x\n", i);
        for (int j = 0; j < len; j++) {
            rs = rs * 1103515245u + 12345u;
            big[j] = "ACGT"[(rs >> 16) & 3];
        }
        fwrite(big, 1, (size_t)len, fp);
        fputs("\n+\n", fp);
        for (int j = 0; j < len; j++) {
            rs = rs * 1103515245u + 12345u;
            big[j] = (char)(33 + ((rs >> 18) & 31));
        }
        fwrite(big, 1, (size_t)len, fp);
        fputc('\n', fp);
    }
    free(big);
    fclose(fp);
}

static NSString *siShardDigest(NSString *fq, unsigned long long batchBytes, BOOL serial,
                               unsigned long long expectReads)
{
    if (serial) setenv("TTIO_THREADS", "1", 1);
    NSError *err = nil;
    NSString *out = siTmp(serial ? "sh-s" : "sh-p", "tio");
    TTIOImportedDataset *d = [[TTIOImportedDataset alloc] init];
    d.genomicStreams[@"g"] = [TTIOFastqReader streamFromPath:fq name:@"g" sampleName:@"s"
                                                  batchReads:0 batchBytes:batchBytes progress:nil];
    BOOL ok = [d writeToPath:out error:&err];
    if (serial) unsetenv("TTIO_THREADS");
    if (!ok) {
        PASS(NO, "shard fastq: write (%s)", [[err localizedDescription] UTF8String] ?: "");
        return nil;
    }
    TTIOGenomicRun *g = [TTIOSpectralDataset readFromFilePath:out error:&err].genomicRuns[@"g"];
    if (g == nil || g.readCount != expectReads) {
        PASS(NO, "shard fastq: run open, %llu reads (want %llu)", g.readCount, expectReads);
        return nil;
    }
    NSString *md5 = bgSam11Md5FromRun(g);
    [g close];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    return md5;
}

static void siFastqShardIdentity(void)
{
    // Mixed lengths: mostly 120 B with a 100 KiB read every 500.
    NSString *fq = siTmp("shard", "fastq");
    siWritePlainFixture(fq, 30000, 500, 100 * 1024);
    NSString *par = siShardDigest(fq, 1ull << 20, NO, 30000);
    NSString *ser = siShardDigest(fq, 1ull << 20, YES, 30000);
    PASS(par != nil && [par isEqualToString:ser],
         "shard fastq: mixed-length digest identical (%s)", [par UTF8String] ?: "");
    [[NSFileManager defaultManager] removeItemAtPath:fq error:NULL];

    // Two 200 KiB records with a 64 KiB batch limit: the file shards,
    // most ranges are empty, order still holds.
    NSString *fq2 = siTmp("shard2", "fastq");
    siWritePlainFixture(fq2, 2, 1, 200 * 1024);
    NSString *par2 = siShardDigest(fq2, 64ull << 10, NO, 2);
    NSString *ser2 = siShardDigest(fq2, 64ull << 10, YES, 2);
    PASS(par2 != nil && [par2 isEqualToString:ser2],
         "shard fastq: sparse-shard digest identical (%s)", [par2 UTF8String] ?: "");
    [[NSFileManager defaultManager] removeItemAtPath:fq2 error:NULL];
}

static void siMzML(void)
{
    NSString *mz = siFixture(@"1min.mzML");
    if (!mz) { PASS(YES, "streaming importers: 1min.mzML unavailable, skipped"); return; }
    NSError *err = nil;
    TTIOSpectralDataset *eagerDs = [TTIOMzMLReader readFromFilePath:mz error:&err];
    TTIOAcquisitionRun *eager = [eagerDs.msRuns.allValues firstObject];
    NSString *out = siTmp("mzml", "tio");
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    TTIOImportedDataset *d = [[TTIOImportedDataset alloc] init];
    d.spectralStreams[@"r"] = [TTIOMzMLReader streamFromPath:mz runName:@"r" batchSpectra:5 progress:nil];
    PASS([d writeToPath:out error:&err], "streaming importers: mzML stream writes (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOAcquisitionRun *run = ds.msRuns[@"r"];
    PASS(run != nil && run.count == eager.count, "streaming importers: streamed mzML run has %lu spectra (%lu)",
         (unsigned long)eager.count, (unsigned long)run.count);
    BOOL same = run != nil;
    for (NSUInteger i = 0; i < run.count && same; i++) {
        TTIOMassSpectrum *a = [run spectrumAtIndex:i error:NULL], *b = [eager spectrumAtIndex:i error:NULL];
        if (![[a.mzArray float64Buffer] isEqualToData:[b.mzArray float64Buffer]]
            || ![[a.intensityArray float64Buffer] isEqualToData:[b.intensityArray float64Buffer]]
            || a.msLevel != b.msLevel || a.scanTimeSeconds != b.scanTimeSeconds) same = NO;
    }
    PASS(same, "streaming importers: streamed mzML spectra equal the eager parse");
    PASS(run.chromatograms.count == eager.chromatograms.count, "streaming importers: chromatograms carried (%lu)",
         (unsigned long)run.chromatograms.count);
    PASS(run.signalCompression == TTIOCompressionFloatDeltaZstd, "streaming importers: streamed mzML run uses codec 17");
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];

    // Registry path with a batch_spectra extra and the file-stem name.
    BOOL ok = [TTIOImporterRegistry encodeFormat:@"mzml" inputs:@[mz] output:out
                                         options:@{@"batch_spectra": @"4"} error:&err];
    PASS(ok, "streaming importers: registry mzml encode (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    PASS(ds2.msRuns[@"1min"] != nil && [ds2.msRuns[@"1min"] count] == eager.count,
         "streaming importers: registry mzml run named after the file (%lu runs)", (unsigned long)ds2.msRuns.count);
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];

    // A missing file surfaces the parser's error through the stream.
    d = [[TTIOImportedDataset alloc] init];
    d.spectralStreams[@"x"] = [TTIOMzMLReader streamFromPath:@"/nonexistent/no.mzML" runName:@"x" batchSpectra:5 progress:nil];
    err = nil;
    PASS(![d writeToPath:out error:&err] && err != nil, "streaming importers: missing mzML is an error (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
}

void testStreamingImporters(void)
{
    @autoreleasepool {
        siBamBatches();
        siBamStreamWrite();
        siFastq();
    siFastqBatchBytes();
    siFastqParallelIdentity();
    siFastqShardIdentity();
        siMzML();
    }
}
