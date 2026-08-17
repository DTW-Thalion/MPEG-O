/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * The committed Python-written blocks_v1 golden fixture: the
 * cross-language decode contract for the block layout.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import <openssl/evp.h>

static NSString *bgFirstExisting(NSArray<NSString *> *paths)
{
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

NSString *bgGoldenPath(void)
{
    return bgFirstExisting(@[@"../python/tests/fixtures/genomic/blocks_v1_golden.tio",
                             @"/home/toddw/TTI-O/python/tests/fixtures/genomic/blocks_v1_golden.tio"]);
}

NSString *bgSamPath(void)
{
    return bgFirstExisting(@[@"Tests/Fixtures/genomic/m87_test.sam",
                             @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/m87_test.sam"]);
}

/* md5 over the sorted lines, each followed by a newline; the digest of
 * python/tests/_digests.py. */
NSString *bgMd5Lines(NSArray<NSString *> *lines)
{
    NSArray *sorted = [lines sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSData *da = [a dataUsingEncoding:NSUTF8StringEncoding], *db = [b dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger n = MIN(da.length, db.length);
        int c = memcmp(da.bytes, db.bytes, n);
        if (c != 0) return c < 0 ? NSOrderedAscending : NSOrderedDescending;
        if (da.length == db.length) return NSOrderedSame;
        return da.length < db.length ? NSOrderedAscending : NSOrderedDescending;
    }];
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_md5(), NULL);
    for (NSString *l in sorted) {
        NSData *d = [l dataUsingEncoding:NSUTF8StringEncoding];
        EVP_DigestUpdate(ctx, d.bytes, d.length);
        EVP_DigestUpdate(ctx, "\n", 1);
    }
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int outLen = 0;
    EVP_DigestFinal_ex(ctx, out, &outLen);
    EVP_MD_CTX_free(ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (unsigned int i = 0; i < outLen; i++) [hex appendFormat:@"%02x", out[i]];
    return hex;
}

/* SAM columns 1-11 of every record, RNEXT "=" expanded to RNAME. */
NSString *bgSam11Md5FromSam(NSString *samPath)
{
    NSString *text = [NSString stringWithContentsOfFile:samPath encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0 || [line hasPrefix:@"@"]) continue;
        NSMutableArray *c = [[line componentsSeparatedByString:@"\t"] mutableCopy];
        if (c.count < 11) continue;
        NSMutableArray *cols = [[c subarrayWithRange:NSMakeRange(0, 11)] mutableCopy];
        if ([cols[6] isEqualToString:@"="]) cols[6] = cols[2];
        [lines addObject:[cols componentsJoinedByString:@"\t"]];
    }
    return bgMd5Lines(lines);
}

NSString *bgSam11Md5FromRun(TTIOGenomicRun *run)
{
    NSMutableArray *lines = [NSMutableArray array];
    NSError *err = nil;
    BOOL ok = [run iterReadsFrom:0 to:run.readCount error:&err
                      usingBlock:^(TTIOAlignedRead *r, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        NSString *seq = r.sequence.length ? r.sequence : @"*";
        NSData *q = r.qualities;
        NSString *qual;
        if (q.length == 0) {
            qual = @"*";
        } else {
            const uint8_t *qb = q.bytes;
            BOOL allFF = YES;
            for (NSUInteger i = 0; i < q.length; i++) if (qb[i] != 0xFF) { allFF = NO; break; }
            qual = allFF ? @"*" : [[NSString alloc] initWithData:q encoding:NSISOLatin1StringEncoding];
        }
        NSString *rnext = r.mateChromosome.length ? r.mateChromosome : @"*";
        [lines addObject:[@[
            r.readName.length ? r.readName : @"*",
            [NSString stringWithFormat:@"%u", (unsigned)r.flags],
            r.chromosome.length ? r.chromosome : @"*",
            [NSString stringWithFormat:@"%lld", (long long)r.position],
            [NSString stringWithFormat:@"%u", (unsigned)r.mappingQuality],
            r.cigar.length ? r.cigar : @"*",
            rnext,
            [NSString stringWithFormat:@"%lld", (long long)r.matePosition],
            [NSString stringWithFormat:@"%d", (int)r.templateLength],
            seq, qual] componentsJoinedByString:@"\t"]];
    }];
    if (!ok) NSLog(@"iterReads failed: %@", err);
    return bgMd5Lines(lines);
}

void testBlocksV1Golden(void)
{
    @autoreleasepool {
        NSString *golden = bgGoldenPath(), *sam = bgSamPath();
        if (!golden || !sam) { PASS(YES, "blocks_v1 golden: fixture unavailable, skipped"); return; }
        NSError *err = nil;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:golden error:&err];
        PASS(ds != nil, "blocks_v1 golden: opens (%s)", [[err localizedDescription] UTF8String] ?: "");
        if (!ds) return;
        TTIOGenomicRun *g = ds.genomicRuns[@"genomic_0001"];
        PASS(g != nil, "blocks_v1 golden: genomic_0001 present");
        if (!g) return;
        PASS([g.layout isEqualToString:@"blocks_v1"], "blocks_v1 golden: layout");
        PASS(g.blockCount == 4, "blocks_v1 golden: 4 blocks (%lu)", (unsigned long)g.blockCount);
        PASS(g.readCount == 10, "blocks_v1 golden: 10 reads (%lu)", (unsigned long)g.readCount);
        NSString *want = bgSam11Md5FromSam(sam), *got = bgSam11Md5FromRun(g);
        PASS([want isEqualToString:got], "blocks_v1 golden: SAM-11 digest matches m87_test.sam (%s vs %s)",
             [want UTF8String], [got UTF8String]);
        [g close];
    }
}
