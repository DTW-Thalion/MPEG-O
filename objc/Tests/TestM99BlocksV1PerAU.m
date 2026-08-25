/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * M99: per-AU encryption over the blocks_v1 genomic layout. The
 * walkers stream block by block; decrypt-in-place restores the
 * channel blobs byte-identically with the block index untouched.
 * Mirrors python/tests/test_m99_blocks_v1_per_au.py.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSpectralDataset+GenomicWrite.h"
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Genomics/TTIOGenomicBlocks.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Protection/TTIOPerAUFile.h"
#import "Transport/TTIOEncryptedTransport.h"
#import "Transport/TTIOTransportWriter.h"
#import "Providers/TTIOHDF5Provider.h"
#import "Providers/TTIOStorageProtocols.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

static NSString *m99TmpPath(NSString *tag)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ttio-m99-%@-%d.tio", tag, (int)getpid()]];
}

static void m99Rm(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSData *m99Key(void)
{
    NSMutableData *k = [NSMutableData dataWithLength:32];
    uint8_t *p = k.mutableBytes;
    for (int i = 0; i < 32; i++) p[i] = (uint8_t)(0x51 + i);
    return k;
}

// Deterministic LCG so runs are reproducible without srand().
static uint32_t m99Next(uint32_t *s)
{
    *s = *s * 1664525u + 1013904223u;
    return *s >> 8;
}

// A multi-chromosome run; zeroEvery > 0 plants zero-length reads,
// crossMates points mates at the other chromosome.
static TTIOWrittenGenomicRun *m99MakeRun(NSUInteger nReads,
                                          uint32_t seed,
                                          NSUInteger zeroEvery,
                                          BOOL crossMates)
{
    uint32_t s = seed;
    NSMutableData *lengths = [NSMutableData dataWithLength:nReads * 4];
    uint32_t *lenP = lengths.mutableBytes;
    uint64_t total = 0;
    for (NSUInteger i = 0; i < nReads; i++) {
        uint32_t l = 60 + (m99Next(&s) % 140);
        if (zeroEvery > 0 && i > 10 && (i % zeroEvery) == 0) l = 0;
        lenP[i] = l;
        total += l;
    }
    NSMutableData *offsets = [NSMutableData dataWithLength:nReads * 8];
    uint64_t *offP = offsets.mutableBytes;
    uint64_t cum = 0;
    for (NSUInteger i = 0; i < nReads; i++) { offP[i] = cum; cum += lenP[i]; }
    NSMutableData *seq = [NSMutableData dataWithLength:(NSUInteger)total];
    NSMutableData *qual = [NSMutableData dataWithLength:(NSUInteger)total];
    uint8_t *seqP = seq.mutableBytes, *qualP = qual.mutableBytes;
    static const char bases[5] = "ACGTN";
    for (NSUInteger i = 0; i < (NSUInteger)total; i++) {
        seqP[i] = (uint8_t)bases[m99Next(&s) % 5];
        qualP[i] = (uint8_t)(33 + (m99Next(&s) % 40));
    }
    NSMutableData *positions = [NSMutableData dataWithLength:nReads * 8];
    NSMutableData *mapqs = [NSMutableData dataWithLength:nReads];
    NSMutableData *flags = [NSMutableData dataWithLength:nReads * 4];
    NSMutableData *matePos = [NSMutableData dataWithLength:nReads * 8];
    NSMutableData *tlens = [NSMutableData dataWithLength:nReads * 4];
    int64_t *posP = positions.mutableBytes;
    uint8_t *mapqP = mapqs.mutableBytes;
    uint32_t *flagP = flags.mutableBytes;
    int64_t *mposP = matePos.mutableBytes;
    int32_t *tlenP = tlens.mutableBytes;
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:nReads];
    NSUInteger half = nReads / 2;
    for (NSUInteger i = 0; i < nReads; i++) {
        posP[i] = (int64_t)(i * 40);
        mapqP[i] = 60;
        flagP[i] = crossMates ? 0x1 : 0;
        mposP[i] = crossMates ? (int64_t)(m99Next(&s) % 10000) : -1;
        tlenP[i] = crossMates ? (int32_t)((m99Next(&s) % 1000) - 500) : 0;
        [cigars addObject:lenP[i]
            ? [NSString stringWithFormat:@"%uM", lenP[i]] : @"*"];
        [names addObject:[NSString stringWithFormat:@"m99r%06lu",
            (unsigned long)i]];
        NSString *own = i < half ? @"chr1" : @"chr2";
        [chroms addObject:own];
        [mateChroms addObject:crossMates
            ? (i < half ? @"chr2" : @"chr1") : @""];
    }
    TTIOWrittenGenomicRun *run = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:(TTIOAcquisitionMode)7
                   referenceUri:@""
                       platform:@"ILLUMINA"
                     sampleName:@"M99"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seq
                      qualities:qual
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
    return [run copyWithOptLegacyWholeChannel:NO];
}

// Write a blocks_v1 file: empty write_minimal, then the stream
// writer against the reopened study group.
static BOOL m99WriteBlocksFile(NSString *path,
                               TTIOWrittenGenomicRun *run,
                               NSUInteger blockReads,
                               NSError **error)
{
    m99Rm(path);
    if (![TTIOSpectralDataset writeMinimalToPath:path
                                           title:@"M99"
                             isaInvestigationId:@"ISA-M99"
                                         msRuns:@{}
                                     genomicRuns:@{}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:error]) return NO;
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (!f) return NO;
    TTIOHDF5Group *study = [f.rootGroup openGroupNamed:@"study" error:error];
    if (!study) { [f close]; return NO; }
    id<TTIOStorageGroup> studyAdapter = [TTIOHDF5Provider adapterForGroup:study];
    TTIOGenomicStreamWriterOptions *o =
        [TTIOGenomicStreamWriterOptions optionsFromRun:run];
    o.blockReads = blockReads;
    TTIOGenomicStreamWriter *w =
        [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:studyAdapter
                                                    runName:@"run"
                                                    options:o];
    NSUInteger n = run.readCount;
    BOOL ok = YES;
    for (NSUInteger st = 0; ok && st < n; st += 100) {
        NSUInteger sp = MIN(st + 100, n);
        ok = [w appendBatch:[TTIOGenomicBlocks sliceRun:run from:st to:sp]
                      error:error];
    }
    if (ok) ok = [w close:error];
    [f close];
    return ok;
}

// (index bytes, sequences blob, qualities blob) snapshot.
static NSArray<NSData *> *m99Snapshot(NSString *path)
{
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    if (!f) return nil;
    TTIOHDF5Group *rg = [[[f.rootGroup openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"genomic_runs" error:NULL]
        openGroupNamed:@"run" error:NULL];
    id<TTIOStorageGroup> a = [TTIOHDF5Provider adapterForGroup:rg];
    NSData *idx = [[[a openGroupNamed:@"blocks" error:NULL]
        openDatasetNamed:@"index" error:NULL] readCanonicalBytes:NULL];
    id<TTIOStorageGroup> sig = [a openGroupNamed:@"signal_channels" error:NULL];
    NSData *seq = nil, *qual = nil;
    if ([sig hasChildNamed:@"sequences"]) {
        seq = [[[sig openGroupNamed:@"sequences" error:NULL]
            openDatasetNamed:@"data" error:NULL] readAll:NULL];
    }
    if ([sig hasChildNamed:@"qualities"]) {
        qual = [[sig openDatasetNamed:@"qualities" error:NULL] readAll:NULL];
    }
    [f close];
    if (!idx || !seq || !qual) return nil;
    return @[idx, seq, qual];
}

static BOOL m99FeatureFlagSet(NSString *path)
{
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    if (!f) return NO;
    NSString *feats = [f.rootGroup stringAttributeNamed:@"ttio_features"
                                                  error:NULL];
    [f close];
    return feats != nil
        && [feats rangeOfString:@"opt_per_au_encryption"].location != NSNotFound;
}

static void m99EncryptShape(void)
{
    NSError *err = nil;
    NSString *path = m99TmpPath(@"shape");
    TTIOWrittenGenomicRun *run = m99MakeRun(900, 3, 0, NO);
    PASS(m99WriteBlocksFile(path, run, 200, &err),
         "M99 shape: blocks_v1 file written (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    NSArray<NSData *> *before = m99Snapshot(path);
    PASS(before != nil, "M99 shape: pre-encrypt snapshot");

    PASS([TTIOPerAUFile encryptFilePath:path key:m99Key()
                          encryptHeaders:NO providerName:nil error:&err],
         "M99 shape: encrypt succeeds on blocks_v1 (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    PASS(m99FeatureFlagSet(path), "M99 shape: opt_per_au_encryption set");

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOHDF5Group *rg = [[[f.rootGroup openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"genomic_runs" error:NULL]
        openGroupNamed:@"run" error:NULL];
    id<TTIOStorageGroup> a = [TTIOHDF5Provider adapterForGroup:rg];
    id<TTIOStorageGroup> sig = [a openGroupNamed:@"signal_channels" error:NULL];
    PASS(![sig hasChildNamed:@"sequences"] && ![sig hasChildNamed:@"qualities"],
         "M99 shape: plaintext channels stripped");
    NSData *idxAfter = [[[a openGroupNamed:@"blocks" error:NULL]
        openDatasetNamed:@"index" error:NULL] readCanonicalBytes:NULL];
    PASS(before != nil && [idxAfter isEqualToData:before[0]],
         "M99 shape: block index untouched");
    for (NSString *ch in @[@"sequences", @"qualities"]) {
        NSString *segName = [NSString stringWithFormat:@"%@_segments", ch];
        id<TTIOStorageDataset> seg = [sig openDatasetNamed:segName error:NULL];
        NSArray *rows = [seg readRows:NULL];
        PASS(rows.count == 900,
             "M99 shape: %s one AU per read across blocks (%lu)",
             ch.UTF8String, (unsigned long)rows.count);
        // Global plaintext offsets: row i's offset is the cumsum of
        // the preceding lengths.
        const uint32_t *lens = (const uint32_t *)run.lengthsData.bytes;
        uint64_t cum = 0; BOOL offsOk = YES;
        for (NSUInteger i = 0; i < rows.count && offsOk; i++) {
            offsOk = [rows[i][@"offset"] unsignedLongLongValue] == cum
                && [rows[i][@"length"] unsignedIntValue] == lens[i];
            cum += lens[i];
        }
        PASS(offsOk, "M99 shape: %s segment offsets are global",
             ch.UTF8String);
    }
    [f close];
    m99Rm(path);
}

static void m99RoundTrip(NSString *tag, TTIOWrittenGenomicRun *run,
                         NSUInteger blockReads)
{
    NSError *err = nil;
    NSString *path = m99TmpPath(tag);
    PASS(m99WriteBlocksFile(path, run, blockReads, &err),
         "M99 %s: blocks_v1 file written (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    NSArray<NSData *> *before = m99Snapshot(path);
    PASS(before != nil, "M99 %s: pre-encrypt snapshot", tag.UTF8String);

    PASS([TTIOPerAUFile encryptFilePath:path key:m99Key()
                          encryptHeaders:NO providerName:nil error:&err],
         "M99 %s: encrypt (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    PASS([TTIOPerAUFile decryptFilePathInPlace:path key:m99Key()
                                  providerName:nil error:&err],
         "M99 %s: decrypt in place (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    PASS(!m99FeatureFlagSet(path), "M99 %s: flag stripped", tag.UTF8String);

    NSArray<NSData *> *after = m99Snapshot(path);
    PASS(after != nil, "M99 %s: post-restore snapshot", tag.UTF8String);
    if (before && after) {
        PASS([after[0] isEqualToData:before[0]],
             "M99 %s: block index byte-identical", tag.UTF8String);
        PASS([after[1] isEqualToData:before[1]],
             "M99 %s: sequences blob byte-identical", tag.UTF8String);
        PASS([after[2] isEqualToData:before[2]],
             "M99 %s: qualities blob byte-identical", tag.UTF8String);
    }

    // The restored run reads back: spot-check first/middle/last.
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOHDF5Group *rg = [[[f.rootGroup openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"genomic_runs" error:NULL]
        openGroupNamed:@"run" error:NULL];
    id<TTIOStorageGroup> a = [TTIOHDF5Provider adapterForGroup:rg];
    TTIOGenomicRun *rd = [TTIOGenomicRun openFromGroup:a name:@"run"
                                                 error:&err];
    PASS(rd != nil, "M99 %s: restored run opens (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    if (rd) {
        NSUInteger n = run.readCount;
        const uint64_t *offs = (const uint64_t *)run.offsetsData.bytes;
        const uint32_t *lens = (const uint32_t *)run.lengthsData.bytes;
        const uint8_t *seqAll = (const uint8_t *)run.sequencesData.bytes;
        BOOL readsOk = YES;
        NSUInteger picks[3] = {0, n / 2, n - 1};
        for (int k = 0; k < 3 && readsOk; k++) {
            NSUInteger i = picks[k];
            TTIOAlignedRead *r = [rd readAtIndex:i error:&err];
            if (!r) { readsOk = NO; break; }
            NSData *want = [NSData dataWithBytes:seqAll + offs[i]
                                          length:lens[i]];
            NSData *got = [r.sequence dataUsingEncoding:NSASCIIStringEncoding];
            readsOk = [got isEqualToData:want]
                && [r.readName isEqualToString:run.readNames[i]];
        }
        PASS(readsOk, "M99 %s: restored reads decode identically",
             tag.UTF8String);
    }
    [f close];
    m99Rm(path);
}

// An aligned run over an embedded reference: sequences go through
// REF_DIFF_V2 and restore must re-encode against the reference.
static TTIOWrittenGenomicRun *m99MakeRefDiffRun(void)
{
    NSUInteger n = 300, L = 120;
    uint32_t s = 33;
    NSMutableData *ref = [NSMutableData dataWithLength:60000];
    uint8_t *refP = ref.mutableBytes;
    static const char bases[4] = "ACGT";
    for (NSUInteger i = 0; i < ref.length; i++)
        refP[i] = (uint8_t)bases[m99Next(&s) % 4];

    NSMutableData *seq = [NSMutableData dataWithLength:n * L];
    NSMutableData *qual = [NSMutableData dataWithLength:n * L];
    NSMutableData *positions = [NSMutableData dataWithLength:n * 8];
    NSMutableData *mapqs = [NSMutableData dataWithLength:n];
    NSMutableData *flags = [NSMutableData dataWithLength:n * 4];
    NSMutableData *offsets = [NSMutableData dataWithLength:n * 8];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * 4];
    NSMutableData *matePos = [NSMutableData dataWithLength:n * 8];
    NSMutableData *tlens = [NSMutableData dataWithLength:n * 4];
    uint8_t *seqP = seq.mutableBytes, *qualP = qual.mutableBytes;
    int64_t *posP = positions.mutableBytes;
    uint8_t *mapqP = mapqs.mutableBytes;
    uint32_t *flagP = flags.mutableBytes;
    uint64_t *offP = offsets.mutableBytes;
    uint32_t *lenP = lengths.mutableBytes;
    int64_t *mposP = matePos.mutableBytes;
    int32_t *tlenP = tlens.mutableBytes;
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        int64_t pos = (int64_t)(i * 150 + 1);
        memcpy(seqP + i * L, refP + pos - 1, L);
        // a couple of mismatches per read so the diff stream is non-empty
        seqP[i * L + 13] = 'A';
        seqP[i * L + 77] = 'T';
        for (NSUInteger k = 0; k < L; k++)
            qualP[i * L + k] = (uint8_t)(33 + (m99Next(&s) % 40));
        posP[i] = pos;
        mapqP[i] = 60;
        flagP[i] = 0;
        offP[i] = i * L;
        lenP[i] = (uint32_t)L;
        mposP[i] = -1;
        tlenP[i] = 0;
        [cigars addObject:@"120M"];
        [names addObject:[NSString stringWithFormat:@"rd%lu", (unsigned long)i]];
        [mateChroms addObject:@""];
        [chroms addObject:@"chr1"];
    }
    TTIOWrittenGenomicRun *run = [([[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:(TTIOAcquisitionMode)7
                   referenceUri:@"m99ref"
                       platform:@"ILLUMINA"
                     sampleName:@"M99"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seq
                      qualities:qual
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib])
        copyWithOptLegacyWholeChannel:NO];
    run.referenceChromSeqs = @{ @"chr1": ref };
    run.embedReference = YES;
    return run;
}

// The v1.0 encrypted transport stream does not carry the blocks_v1
// sidecars; the sender must refuse.
static void m99TransportRefusal(void)
{
    NSError *err = nil;
    NSString *path = m99TmpPath(@"send");
    TTIOWrittenGenomicRun *run = m99MakeRun(300, 11, 0, NO);
    PASS(m99WriteBlocksFile(path, run, 100, &err),
         "M99 send: blocks_v1 file written (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    PASS([TTIOPerAUFile encryptFilePath:path key:m99Key()
                          encryptHeaders:NO providerName:nil error:&err],
         "M99 send: encrypt (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    NSString *outPath = m99TmpPath(@"send-out");
    m99Rm(outPath);
    TTIOTransportWriter *tw =
        [[TTIOTransportWriter alloc] initWithOutputPath:outPath];
    err = nil;
    BOOL ok = [TTIOEncryptedTransport writeEncryptedDataset:path
                                                       writer:tw
                                                 providerName:nil
                                                        error:&err];
    [tw close];
    PASS(!ok, "M99 send: writeEncryptedDataset refuses blocks_v1");
    PASS([err.localizedDescription rangeOfString:@"blocks_v1"].location
             != NSNotFound,
         "M99 send: refusal names blocks_v1 (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    m99Rm(outPath);
    m99Rm(path);
}

// Qualities conditioned on the base at each position, so the
// sequence-conditioned FQZ V5 strategy wins when it is allowed and
// the V4 family wins when it is not. Sized so each 6000-read block
// carries >= 1 MiB of qualities, the auto-tune floor below which V5
// is never raced (TTIO_M94Z_V5_MIN_QUALITIES).
static TTIOWrittenGenomicRun *m99MakeCorrelatedRun(void)
{
    NSUInteger n = 12000, L = 200;
    uint32_t s = 17;
    NSUInteger total = n * L;
    NSMutableData *seq = [NSMutableData dataWithLength:total];
    NSMutableData *qual = [NSMutableData dataWithLength:total];
    uint8_t *seqP = seq.mutableBytes, *qualP = qual.mutableBytes;
    static const char bases[4] = "ACGT";
    uint8_t baseQ[256] = {0};
    baseQ['A'] = 38; baseQ['C'] = 52; baseQ['G'] = 60; baseQ['T'] = 45;
    for (NSUInteger i = 0; i < total; i++) {
        seqP[i] = (uint8_t)bases[m99Next(&s) % 4];
        qualP[i] = (uint8_t)(baseQ[seqP[i]] + (m99Next(&s) % 3));
    }
    NSMutableData *lengths = [NSMutableData dataWithLength:n * 4];
    NSMutableData *offsets = [NSMutableData dataWithLength:n * 8];
    NSMutableData *positions = [NSMutableData dataWithLength:n * 8];
    NSMutableData *mapqs = [NSMutableData dataWithLength:n];
    NSMutableData *flags = [NSMutableData dataWithLength:n * 4];
    NSMutableData *matePos = [NSMutableData dataWithLength:n * 8];
    NSMutableData *tlens = [NSMutableData dataWithLength:n * 4];
    uint32_t *lenP = lengths.mutableBytes;
    uint64_t *offP = offsets.mutableBytes;
    int64_t *posP = positions.mutableBytes;
    uint8_t *mapqP = mapqs.mutableBytes;
    int64_t *mposP = matePos.mutableBytes;
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        lenP[i] = (uint32_t)L;
        offP[i] = i * L;
        posP[i] = (int64_t)(i * 40);
        mapqP[i] = 60;
        mposP[i] = -1;
        [cigars addObject:@"200M"];
        [names addObject:[NSString stringWithFormat:@"m99c%06lu",
            (unsigned long)i]];
        [mateChroms addObject:@""];
        [chroms addObject:@"chr1"];
    }
    return [([[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:(TTIOAcquisitionMode)7
                   referenceUri:@""
                       platform:@"ILLUMINA"
                     sampleName:@"M99"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seq
                      qualities:qual
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib])
        copyWithOptLegacyWholeChannel:NO];
}

static id<TTIOStorageGroup> m99RunAdapter(TTIOHDF5File *f)
{
    TTIOHDF5Group *rg = [[[f.rootGroup openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"genomic_runs" error:NULL]
        openGroupNamed:@"run" error:NULL];
    return rg ? [TTIOHDF5Provider adapterForGroup:rg] : nil;
}

static BOOL m99RunAttrInt(NSString *path, NSString *name, int64_t *out)
{
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    if (!f) return NO;
    id<TTIOStorageGroup> a = m99RunAdapter(f);
    BOOL has = a != nil && [a hasAttributeNamed:name];
    if (has && out) {
        *out = [[a attributeValueForName:name error:NULL] longLongValue];
    }
    [f close];
    return has;
}

static BOOL m99StripRunAttr(NSString *path, NSString *name)
{
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:NULL];
    if (!f) return NO;
    id<TTIOStorageGroup> a = m99RunAdapter(f);
    BOOL ok = a != nil && [a deleteAttributeNamed:name error:NULL];
    [f close];
    return ok;
}

// Reads of the restored file decode to the plaintext the run was
// written with (sequences, qualities, names; first/middle/last).
static BOOL m99ReadsDecode(NSString *path, TTIOWrittenGenomicRun *run)
{
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    if (!f) return NO;
    id<TTIOStorageGroup> a = m99RunAdapter(f);
    TTIOGenomicRun *rd = a
        ? [TTIOGenomicRun openFromGroup:a name:@"run" error:&err] : nil;
    BOOL ok = rd != nil;
    if (ok) {
        NSUInteger n = run.readCount;
        const uint64_t *offs = (const uint64_t *)run.offsetsData.bytes;
        const uint32_t *lens = (const uint32_t *)run.lengthsData.bytes;
        const uint8_t *seqAll = (const uint8_t *)run.sequencesData.bytes;
        const uint8_t *qualAll = (const uint8_t *)run.qualitiesData.bytes;
        NSUInteger picks[3] = {0, n / 2, n - 1};
        for (int k = 0; k < 3 && ok; k++) {
            NSUInteger i = picks[k];
            TTIOAlignedRead *r = [rd readAtIndex:i error:&err];
            if (!r) { ok = NO; break; }
            NSData *wantSeq = [NSData dataWithBytes:seqAll + offs[i]
                                             length:lens[i]];
            NSData *wantQual = [NSData dataWithBytes:qualAll + offs[i]
                                              length:lens[i]];
            ok = [[r.sequence dataUsingEncoding:NSASCIIStringEncoding]
                     isEqualToData:wantSeq]
                && [r.qualities isEqualToData:wantQual]
                && [r.readName isEqualToString:run.readNames[i]];
        }
    }
    [f close];
    return ok;
}

// Offsets in blocks/index are cumulative sums of the lengths and
// cover the whole channel blob, per channel.
static BOOL m99IndexConsistent(NSString *path)
{
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    if (!f) return NO;
    id<TTIOStorageGroup> a = m99RunAdapter(f);
    NSArray *rows = [[[a openGroupNamed:@"blocks" error:NULL]
        openDatasetNamed:@"index" error:NULL] readRows:NULL];
    id<TTIOStorageGroup> sig =
        [a openGroupNamed:@"signal_channels" error:NULL];
    BOOL ok = rows != nil && sig != nil;
    for (NSString *ch in @[@"sequences", @"qualities"]) {
        if (!ok) break;
        NSData *blob = [ch isEqualToString:@"sequences"]
            ? [[[sig openGroupNamed:@"sequences" error:NULL]
                openDatasetNamed:@"data" error:NULL] readAll:NULL]
            : [[sig openDatasetNamed:ch error:NULL] readAll:NULL];
        uint64_t cum = 0;
        for (NSDictionary *r in rows) {
            if ([r[[ch stringByAppendingString:@"_off"]]
                    unsignedLongLongValue] != cum) { ok = NO; break; }
            cum += [r[[ch stringByAppendingString:@"_len"]]
                       unsignedLongLongValue];
        }
        ok = ok && blob != nil && cum == (uint64_t)blob.length;
    }
    [f close];
    return ok;
}

// The writer persists non-default policy; restore honours it, so the
// round trip stays byte-identical for non-default policy too.
static void m99PolicyRoundTrip(NSString *tag,
                               TTIOWrittenGenomicRun *runPolicy,
                               TTIOWrittenGenomicRun *runDefault,
                               NSString *attrName,
                               int64_t attrWant,
                               NSUInteger blockReads,
                               NSUInteger blobIdx)
{
    NSError *err = nil;
    NSString *path = m99TmpPath(tag);
    NSString *defPath =
        m99TmpPath([tag stringByAppendingString:@"-default"]);
    PASS(m99WriteBlocksFile(path, runPolicy, blockReads, &err),
         "M99 %s: policy file written (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    PASS(m99WriteBlocksFile(defPath, runDefault, blockReads, &err),
         "M99 %s: default file written (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    NSArray<NSData *> *before = m99Snapshot(path);
    NSArray<NSData *> *defSnap = m99Snapshot(defPath);
    PASS(before != nil && defSnap != nil
             && ![before[blobIdx] isEqualToData:defSnap[blobIdx]],
         "M99 %s: the policy shapes the blob, else this proves nothing",
         tag.UTF8String);
    int64_t got = 0;
    PASS(m99RunAttrInt(path, attrName, &got) && got == attrWant,
         "M99 %s: @%s persisted (%lld)", tag.UTF8String,
         attrName.UTF8String, (long long)got);

    PASS([TTIOPerAUFile encryptFilePath:path key:m99Key()
                          encryptHeaders:NO providerName:nil error:&err],
         "M99 %s: encrypt (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    PASS([TTIOPerAUFile decryptFilePathInPlace:path key:m99Key()
                                  providerName:nil error:&err],
         "M99 %s: decrypt in place (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    NSArray<NSData *> *after = m99Snapshot(path);
    PASS(before != nil && after != nil
             && [after[0] isEqualToData:before[0]]
             && [after[1] isEqualToData:before[1]]
             && [after[2] isEqualToData:before[2]],
         "M99 %s: round trip byte-identical under the policy",
         tag.UTF8String);
    m99Rm(defPath);
    m99Rm(path);
}

// The persisted policy attr is stripped, so restore re-encodes with
// the default policy, the blob lengths differ, and the fallback
// rewrites the block index; the file stays readable.
static void m99FallbackRoundTrip(NSString *tag,
                                 TTIOWrittenGenomicRun *run,
                                 NSString *attrName,
                                 NSUInteger blockReads)
{
    NSError *err = nil;
    NSString *path = m99TmpPath(tag);
    PASS(m99WriteBlocksFile(path, run, blockReads, &err),
         "M99 %s: file written (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    PASS(m99StripRunAttr(path, attrName),
         "M99 %s: @%s stripped", tag.UTF8String, attrName.UTF8String);
    NSArray<NSData *> *before = m99Snapshot(path);
    PASS(before != nil, "M99 %s: pre-encrypt snapshot", tag.UTF8String);

    PASS([TTIOPerAUFile encryptFilePath:path key:m99Key()
                          encryptHeaders:NO providerName:nil error:&err],
         "M99 %s: encrypt (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");
    PASS([TTIOPerAUFile decryptFilePathInPlace:path key:m99Key()
                                  providerName:nil error:&err],
         "M99 %s: decrypt in place succeeds (%s)", tag.UTF8String,
         [[err localizedDescription] UTF8String] ?: "");

    NSArray<NSData *> *after = m99Snapshot(path);
    PASS(before != nil && after != nil
             && ![after[0] isEqualToData:before[0]],
         "M99 %s: the fallback rewrote the block index, else this "
         "exercised the normal path", tag.UTF8String);
    PASS(m99IndexConsistent(path),
         "M99 %s: rewritten index covers the blobs", tag.UTF8String);
    PASS(m99ReadsDecode(path, run),
         "M99 %s: restored reads decode identically", tag.UTF8String);
    m99Rm(path);
}

static void m99DefaultPolicyNoAttrs(void)
{
    NSError *err = nil;
    NSString *path = m99TmpPath(@"noattrs");
    PASS(m99WriteBlocksFile(path, m99MakeRun(300, 5, 0, NO), 100, &err),
         "M99 noattrs: file written (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    PASS(!m99RunAttrInt(path, @"ref_diff_slice_bytes", NULL)
             && !m99RunAttrInt(path, @"opt_disable_qualities_v5", NULL),
         "M99 noattrs: default policy writes no policy attrs");
    m99Rm(path);
}

void testM99BlocksV1PerAU(void)
{
    m99EncryptShape();
    m99TransportRefusal();
    m99RoundTrip(@"plain", m99MakeRun(900, 7, 0, NO), 200);
    m99RoundTrip(@"zerolen", m99MakeRun(700, 9, 97, NO), 150);
    m99RoundTrip(@"xmates", m99MakeRun(600, 21, 0, YES), 150);
    m99RoundTrip(@"refdiff", m99MakeRefDiffRun(), 80);
    m99DefaultPolicyNoAttrs();

    TTIOWrittenGenomicRun *slicePolicy = m99MakeRefDiffRun();
    slicePolicy.refDiffSliceBytes = 4096;
    m99PolicyRoundTrip(@"slicepol", slicePolicy, m99MakeRefDiffRun(),
                       @"ref_diff_slice_bytes", 4096, 80, 1);
    TTIOWrittenGenomicRun *v5Policy = m99MakeCorrelatedRun();
    v5Policy.optDisableQualitiesV5 = YES;
    m99PolicyRoundTrip(@"v5pol", v5Policy, m99MakeCorrelatedRun(),
                       @"opt_disable_qualities_v5", 1, 6000, 2);

    TTIOWrittenGenomicRun *sliceFb = m99MakeRefDiffRun();
    sliceFb.refDiffSliceBytes = 4096;
    m99FallbackRoundTrip(@"slicefb", sliceFb,
                         @"ref_diff_slice_bytes", 80);
    TTIOWrittenGenomicRun *v5Fb = m99MakeCorrelatedRun();
    v5Fb.optDisableQualitiesV5 = YES;
    m99FallbackRoundTrip(@"v5fb", v5Fb,
                         @"opt_disable_qualities_v5", 6000);
}
