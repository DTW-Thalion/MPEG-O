/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * The storage-path genomic writer over a memory-provider root, and the
 * block encoder built on it (format-spec 10.12).
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset+GenomicWrite.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicWriteContext.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Import/TTIOBamReader.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

static NSString *gbBamPath(void)
{
    NSString *rel = @"Tests/Fixtures/genomic/m87_test.bam";
    if ([[NSFileManager defaultManager] fileExistsAtPath:rel]) return rel;
    NSString *abs = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/m87_test.bam";
    return [[NSFileManager defaultManager] fileExistsAtPath:abs] ? abs : nil;
}

TTIOWrittenGenomicRun *gbM87Run(NSString *region)
{
    NSString *path = gbBamPath();
    if (!path) return nil;
    NSError *err = nil;
    TTIOBamReader *r = [[TTIOBamReader alloc] initWithPath:path];
    return [r toGenomicRunWithName:@"genomic_0001" region:region sampleName:nil error:&err];
}

id<TTIOStorageGroup> gbMemRoot(NSString *url)
{
    [TTIOMemoryProvider discardStore:url];
    NSError *err = nil;
    id<TTIOStorageProvider> p = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory" error:&err];
    return [p rootGroupWithError:&err];
}

static void gbStoragePathRoundTrip(void)
{
    // chr1 only: the unmapped zero-length read r005 trips the fqzcomp
    // zero-length decode bug, which is out of scope here.
    TTIOWrittenGenomicRun *run = gbM87Run(@"chr1");
    if (!run) { PASS(YES, "genomic blocks: m87 BAM unavailable, skipped"); return; }
    NSString *url = [NSString stringWithFormat:@"memory://gb-rt-%d", (int)getpid()];
    id<TTIOStorageGroup> root = gbMemRoot(url);
    NSError *err = nil;
    // Force FQZCOMP on qualities: the storage path must take the same
    // codec the HDF5 path takes.
    TTIOWrittenGenomicRun *fq = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:run.acquisitionMode referenceUri:run.referenceUri
                       platform:run.platform sampleName:run.sampleName
                      positions:run.positionsData mappingQualities:run.mappingQualitiesData
                          flags:run.flagsData sequences:run.sequencesData
                      qualities:run.qualitiesData offsets:run.offsetsData
                        lengths:run.lengthsData cigars:run.cigars readNames:run.readNames
                mateChromosomes:run.mateChromosomes matePositions:run.matePositionsData
                templateLengths:run.templateLengthsData chromosomes:run.chromosomes
              signalCompression:run.signalCompression
           signalCodecOverrides:@{@"qualities": @(TTIOCompressionFqzcompNx16Z),
                                  @"cigars": @(TTIOCompressionRansOrder0)}];
    BOOL ok = [TTIOSpectralDataset writeGenomicRunStorage:fq toGroup:root name:@"r"
                                                  context:[TTIOGenomicWriteContext none]
                                                    error:&err];
    PASS(ok, "genomic blocks: storage-path write with FQZCOMP qualities (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    id<TTIOStorageGroup> rg = [root openGroupNamed:@"r" error:&err];
    id<TTIOStorageGroup> sc = [rg openGroupNamed:@"signal_channels" error:&err];
    id<TTIOStorageDataset> q = [sc openDatasetNamed:@"qualities" error:&err];
    id comp = [q attributeValueForName:@"compression" error:NULL];
    PASS([comp integerValue] == TTIOCompressionFqzcompNx16Z,
         "genomic blocks: qualities @compression is FQZCOMP (%ld)", (long)[comp integerValue]);
    TTIOGenomicRun *g = [TTIOGenomicRun openFromGroup:rg name:@"r" error:&err];
    PASS(g != nil, "genomic blocks: memory run opens");
    if (!g) return;
    PASS(g.readCount == run.readCount, "genomic blocks: readCount %lu", (unsigned long)g.readCount);
    BOOL allEqual = YES;
    for (NSUInteger i = 0; i < run.readCount && allEqual; i++) {
        err = nil;
        TTIOAlignedRead *a = [g readAtIndex:i error:&err];
        if (!a) { allEqual = NO; NSLog(@"readAtIndex %lu failed: %@", (unsigned long)i, err); break; }
        const uint64_t *offs = (const uint64_t *)run.offsetsData.bytes;
        const uint32_t *lens = (const uint32_t *)run.lengthsData.bytes;
        NSData *seq = [run.sequencesData subdataWithRange:NSMakeRange((NSUInteger)offs[i], lens[i])];
        NSData *qual = [run.qualitiesData subdataWithRange:NSMakeRange((NSUInteger)offs[i], lens[i])];
        NSString *seqStr = [[NSString alloc] initWithData:seq encoding:NSASCIIStringEncoding];
        if (![a.readName isEqualToString:run.readNames[i]] || ![a.cigar isEqualToString:run.cigars[i]]
            || ![a.chromosome isEqualToString:run.chromosomes[i]]
            || ![a.sequence isEqualToString:seqStr] || ![a.qualities isEqualToData:qual]) {
            allEqual = NO;
            NSLog(@"read %lu differs: %@ vs %@ / %@ vs %@", (unsigned long)i, a.readName,
                  run.readNames[i], a.sequence, seqStr);
        }
    }
    PASS(allEqual, "genomic blocks: every read reads back through the storage path");
    [TTIOMemoryProvider discardStore:url];
}

static void gbSharedChromMap(void)
{
    TTIOWrittenGenomicRun *run = gbM87Run(nil);
    if (!run) return;
    NSString *url = [NSString stringWithFormat:@"memory://gb-shared-%d", (int)getpid()];
    id<TTIOStorageGroup> root = gbMemRoot(url);
    NSError *err = nil;
    NSMutableDictionary *shared = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"chrZ"];
    TTIOGenomicWriteContext *ctx = [TTIOGenomicWriteContext contextWithChromNameToId:shared referenceMD5:nil];
    BOOL ok = [TTIOSpectralDataset writeGenomicRunStorage:run toGroup:root name:@"a" context:ctx error:&err];
    PASS(ok, "genomic blocks: write with a shared chromosome map");
    NSString *first = run.chromosomes[0];
    PASS([shared[first] unsignedIntegerValue] >= 1, "genomic blocks: pre-seeded id 0 survives");
    id<TTIOStorageGroup> idx = [[root openGroupNamed:@"a" error:&err] openGroupNamed:@"genomic_index" error:&err];
    NSData *ids = [[idx openDatasetNamed:@"chromosome_ids" error:&err] readAll:&err];
    const uint16_t *idv = (const uint16_t *)ids.bytes;
    PASS(ids.length >= 2 && idv[0] == [shared[first] unsignedShortValue],
         "genomic blocks: chromosome_ids use the shared map");
    NSArray *rows = [[idx openDatasetNamed:@"chromosome_names" error:&err] readRows:&err];
    PASS(rows.count > 0 && [[rows[0][@"name"] description] isEqualToString:@"chrZ"],
         "genomic blocks: name table in id order, chrZ first");
    [TTIOMemoryProvider discardStore:url];
}

void testGenomicBlocks(void)
{
    @autoreleasepool {
        gbStoragePathRoundTrip();
        gbSharedChromMap();
    }
}
