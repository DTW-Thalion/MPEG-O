/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Reading blocks_v1 through TTIOGenomicRun: block policies against the
 * whole run, the unknown-layout error, a partial (unclosed) file,
 * signatures and a multi-block transport round trip.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSpectralDataset+GenomicWrite.h"
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOGenomicWriteContext.h"
#import "Protection/TTIOSignatureManager.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>
#include <hdf5.h>

extern TTIOWrittenGenomicRun *gbM87Run(NSString *region);
extern id<TTIOStorageGroup> gbMemRoot(NSString *url);
extern NSString *bgSam11Md5FromRun(TTIOGenomicRun *run);

static NSString *gbrTmp(const char *tag)
{
    return [NSString stringWithFormat:@"/tmp/gbr-%s-%d.tio", tag, (int)getpid()];
}

/* A memory study holding run "g" written with the given block policy;
 * returns the opened run. */
static TTIOGenomicRun *gbrWriteMem(TTIOWrittenGenomicRun *run, NSString *url, NSUInteger blockReads,
                                   BOOL closeWriter, NSError **error)
{
    id<TTIOStorageGroup> root = gbMemRoot(url);
    id<TTIOStorageGroup> study = [root createGroupNamed:@"study" error:error];
    TTIOGenomicStreamWriterOptions *o = [TTIOGenomicStreamWriterOptions optionsFromRun:run];
    o.blockReads = blockReads;
    TTIOGenomicStreamWriter *w = [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study runName:@"g" options:o];
    if (![w appendBatch:run error:error]) return nil;
    if (closeWriter) { if (![w close:error]) return nil; }
    else { if (![w flush:error]) return nil; }
    id<TTIOStorageGroup> rg = [[study openGroupNamed:@"genomic_runs" error:error] openGroupNamed:@"g" error:error];
    return [TTIOGenomicRun openFromGroup:rg name:@"g" error:error];
}

static void gbrPolicies(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) { PASS(YES, "blocks reader: m87 BAM unavailable, skipped"); return; }
    NSError *err = nil;
    NSString *urlW = [NSString stringWithFormat:@"memory://gbr-whole-%d", (int)getpid()];
    id<TTIOStorageGroup> root = gbMemRoot(urlW);
    TTIOWrittenGenomicRun *legacy = [run copyWithOptLegacyWholeChannel:YES];
    BOOL ok = [TTIOSpectralDataset writeGenomicRunStorage:legacy toGroup:root name:@"g"
                                                  context:[TTIOGenomicWriteContext none] error:&err];
    TTIOGenomicRun *whole = ok ? [TTIOGenomicRun openFromGroup:[root openGroupNamed:@"g" error:&err] name:@"g" error:&err] : nil;
    PASS(whole != nil && [whole.layout isEqualToString:@"whole"] && whole.blockCount == 1,
         "blocks reader: whole-channel reference run");
    NSString *want = bgSam11Md5FromRun(whole);
    NSUInteger policies[] = {1, 3, 1000000};
    for (int p = 0; p < 3; p++) {
        NSString *url = [NSString stringWithFormat:@"memory://gbr-p%d-%d", p, (int)getpid()];
        TTIOGenomicRun *g = gbrWriteMem(run, url, policies[p], YES, &err);
        PASS(g != nil, "blocks reader: policy %lu opens (%s)", (unsigned long)policies[p],
             [[err localizedDescription] UTF8String] ?: "");
        if (!g) continue;
        PASS([g.layout isEqualToString:@"blocks_v1"] && g.readCount == run.readCount,
             "blocks reader: policy %lu layout and read count", (unsigned long)policies[p]);
        NSUInteger expectBlocks = policies[p] == 1 ? 10 : (policies[p] == 3 ? 4 : 3);
        PASS(g.blockCount == expectBlocks, "blocks reader: policy %lu gives %lu blocks (%lu)",
             (unsigned long)policies[p], (unsigned long)expectBlocks, (unsigned long)g.blockCount);
        PASS([bgSam11Md5FromRun(g) isEqualToString:want],
             "blocks reader: policy %lu reads equal the whole run", (unsigned long)policies[p]);
        // Random access across blocks, both directions.
        TTIOAlignedRead *last = [g readAtIndex:run.readCount - 1 error:&err];
        TTIOAlignedRead *first = [g readAtIndex:0 error:&err];
        PASS(first && last && [first.readName isEqualToString:run.readNames[0]]
             && [last.readName isEqualToString:run.readNames[run.readCount - 1]],
             "blocks reader: policy %lu random access", (unsigned long)policies[p]);
        PASS([g readAtIndex:run.readCount error:NULL] == nil, "blocks reader: policy %lu out of range is nil",
             (unsigned long)policies[p]);
        // Whole-channel accessors concatenate over blocks.
        PASS([[g wholeSequencesData] isEqualToData:run.sequencesData]
             && [[g wholeQualitiesData] isEqualToData:run.qualitiesData]
             && [[g allReadNames] isEqualToArray:run.readNames],
             "blocks reader: policy %lu whole-channel accessors", (unsigned long)policies[p]);
        NSArray *chromNames = [g chromosomeNames];
        PASS(chromNames.count == 3 && [chromNames[0] isEqualToString:@"chr1"],
             "blocks reader: policy %lu chromosomeNames", (unsigned long)policies[p]);
        // The per-read index loads lazily and matches.
        PASS([g.index lengthAt:2] == 100 && [[g.index chromosomeAt:9] isEqualToString:@"*"],
             "blocks reader: policy %lu lazy index", (unsigned long)policies[p]);
        [g close];
        [TTIOMemoryProvider discardStore:url];
    }
    [TTIOMemoryProvider discardStore:urlW];
}

static void gbrUnknownLayout(void)
{
    NSString *url = [NSString stringWithFormat:@"memory://gbr-unknown-%d", (int)getpid()];
    id<TTIOStorageGroup> root = gbMemRoot(url);
    NSError *err = nil;
    id<TTIOStorageGroup> rg = [root createGroupNamed:@"g" error:&err];
    [rg setAttributeValue:@"blocks_v9" forName:@"layout" error:&err];
    [rg createGroupNamed:@"genomic_index" error:&err];
    err = nil;
    TTIOGenomicRun *g = [TTIOGenomicRun openFromGroup:rg name:@"g" error:&err];
    PASS(g == nil && err != nil && err.code == TTIOErrorUnsupportedLayout,
         "blocks reader: unknown layout is an error (%s)", [[err localizedDescription] UTF8String] ?: "");
    [TTIOMemoryProvider discardStore:url];
}

static void gbrPartial(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSError *err = nil;
    NSString *url = [NSString stringWithFormat:@"memory://gbr-partial-%d", (int)getpid()];
    // Flushed but never closed: the blocks written so far read back.
    TTIOGenomicRun *g = gbrWriteMem(run, url, 3, NO, &err);
    PASS(g != nil && g.readCount == run.readCount && g.blockCount == 4,
         "blocks reader: unclosed run reads its flushed blocks (%s)", [[err localizedDescription] UTF8String] ?: "");
    TTIOAlignedRead *r = g ? [g readAtIndex:4 error:&err] : nil;
    PASS(r != nil && [r.readName isEqualToString:run.readNames[4]],
         "blocks reader: read from a partial run (%s)", [[err localizedDescription] UTF8String] ?: "");
    [g close];
    [TTIOMemoryProvider discardStore:url];
}

static void gbrSignatures(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSError *err = nil;
    NSString *path = gbrTmp("sig");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path title:@"t" isaInvestigationId:@"i"
                                              msRuns:@{} genomicRuns:@{@"genomic_0001": run}
                                     identifications:nil quantifications:nil provenanceRecords:nil error:&err];
    PASS(ok, "blocks reader: signature fixture written");
    NSMutableData *key = [NSMutableData dataWithLength:32];
    memset(key.mutableBytes, 0x42, 32);
    NSDictionary *sigs = [TTIOSignatureManager signGenomicRun:@"genomic_0001" inFile:path withKey:key error:&err];
    PASS(sigs != nil && sigs[@"signal_channels/sequences/data"] != nil && sigs[@"signal_channels/qualities"] != nil
         && sigs[@"blocks/index"] != nil && sigs[@"genomic_index/lengths"] != nil,
         "blocks reader: sequences/data, qualities, blocks/index and the index columns signed (%lu)",
         (unsigned long)sigs.count);
    PASS([TTIOSignatureManager verifyGenomicRun:@"genomic_0001" inFile:path withKey:key error:&err],
         "blocks reader: signed blocks run verifies");
    // Tamper with the block index and verify again.
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:NULL];
    hid_t did = H5Dopen2(f.rootGroup.groupId, "/study/genomic_runs/genomic_0001/signal_channels/qualities", H5P_DEFAULT);
    if (did >= 0) {
        hid_t sp = H5Dget_space(did);
        hssize_t n = H5Sget_simple_extent_npoints(sp);
        H5Sclose(sp);
        if (n > 0) {
            uint8_t *buf = calloc((size_t)n, 1);
            H5Dread(did, H5T_STD_U8LE, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
            buf[0] ^= 0x01;
            H5Dwrite(did, H5T_STD_U8LE, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
            free(buf);
        }
        H5Dclose(did);
    }
    [f close];
    PASS(![TTIOSignatureManager verifyGenomicRun:@"genomic_0001" inFile:path withKey:key error:NULL],
         "blocks reader: tampered qualities fail verification");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void gbrTransport(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSError *err = nil;
    NSString *src = gbrTmp("tr-src"), *rt = gbrTmp("tr-rt");
    [[NSFileManager defaultManager] removeItemAtPath:src error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:rt error:NULL];
    // A three-block file (chromosome cuts under the default policy).
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:src title:@"t" isaInvestigationId:@"i"
                                              msRuns:@{} genomicRuns:@{@"genomic_0001": run}
                                     identifications:nil quantifications:nil provenanceRecords:nil error:&err];
    TTIOSpectralDataset *ds = ok ? [TTIOSpectralDataset readFromFilePath:src error:&err] : nil;
    TTIOGenomicRun *g = ds.genomicRuns[@"genomic_0001"];
    PASS(g != nil && g.blockCount == 3, "blocks reader: transport source has 3 blocks (%lu)",
         (unsigned long)g.blockCount);
    NSString *want = bgSam11Md5FromRun(g);
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([tw writeDataset:ds error:&err], "blocks reader: transport writeDataset (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    [tw close];
    TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([tr writeTtioToPath:rt error:&err], "blocks reader: transport materialises (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    TTIOSpectralDataset *back = [TTIOSpectralDataset readFromFilePath:rt error:&err];
    TTIOGenomicRun *gb = back.genomicRuns[@"genomic_0001"];
    PASS(gb != nil && gb.readCount == run.readCount, "blocks reader: round-tripped run opens");
    PASS(gb && [bgSam11Md5FromRun(gb) isEqualToString:want], "blocks reader: multi-block transport round trip is lossless");
    [g close];
    [gb close];
    [[NSFileManager defaultManager] removeItemAtPath:src error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:rt error:NULL];
}

void testGenomicBlocksReader(void)
{
    @autoreleasepool {
        gbrPolicies();
        gbrUnknownLayout();
        gbrPartial();
        gbrSignatures();
        gbrTransport();
    }
}
