// TestM97LongReadProfile.m — M97 long-read profile: the @read_role
// attribute, the QUALITY_BINNED platform guard, and the REF_DIFF_V2
// slice_bytes byte budget through the writer paths.
//
// Mirrors:
//   python/tests/test_m97_long_read_profile.py
//   java/src/test/java/.../M97LongReadProfileTest.java
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSpectralDataset+GenomicWrite.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Genomics/TTIOGenomicBlocks.h"
#import "Genomics/TTIOGenomicWriteContext.h"
#import "Codecs/TTIOQuality.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

static NSString *m97TmpPath(NSString *tag)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m97_%d_%@.tio",
            (int)getpid(), tag];
}

static void m97Rm(NSString *p)
{
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

/** Reference: 1000 x "ACGTACGTAC" (10 000 bp). */
static NSData *m97Ref(void)
{
    NSData *unit = [@"ACGTACGTAC" dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *d = [NSMutableData data];
    for (int i = 0; i < 1000; i++) [d appendData:unit];
    return d;
}

/** An aligned 40-read single-chromosome run, 10 bp per read, positions
 *  i*20 + 1, cigar "10M". Legacy whole-channel layout so the refdiff_v2
 *  blob sits at a fixed dataset path. */
static TTIOWrittenGenomicRun *m97MakeAlignedRun(NSString *platform)
{
    NSUInteger n = 40;
    NSUInteger L = 10;

    NSMutableData *seqData  = [NSMutableData dataWithCapacity:n * L];
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    for (NSUInteger i = 0; i < n; i++)
        [seqData appendBytes:"ACGTACGTAC" length:L];
    memset(qualData.mutableBytes, 30, n * L);

    NSMutableData *posD = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *mqD  = [NSMutableData dataWithLength:n * sizeof(uint8_t)];
    NSMutableData *flD  = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *offD = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    NSMutableData *lenD = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *mpD  = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *tlD  = [NSMutableData dataWithLength:n * sizeof(int32_t)];

    int64_t  *pos = (int64_t  *)posD.mutableBytes;
    uint8_t  *mq  = (uint8_t  *)mqD.mutableBytes;
    uint32_t *fl  = (uint32_t *)flD.mutableBytes;
    uint64_t *off = (uint64_t *)offD.mutableBytes;
    uint32_t *len = (uint32_t *)lenD.mutableBytes;
    int64_t  *mp  = (int64_t  *)mpD.mutableBytes;
    int32_t  *tl  = (int32_t  *)tlD.mutableBytes;

    for (NSUInteger i = 0; i < n; i++) {
        pos[i] = (int64_t)(i * 20 + 1);
        mq[i]  = 60;
        fl[i]  = 0;
        off[i] = i * L;
        len[i] = (uint32_t)L;
        mp[i]  = -1;
        tl[i]  = 0;
    }

    NSMutableArray *chroms     = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    NSMutableArray *cigars     = [NSMutableArray array];
    NSMutableArray *readNames  = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [chroms     addObject:@"22"];
        [mateChroms addObject:@"*"];
        [cigars     addObject:@"10M"];
        [readNames  addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
    }

    TTIOWrittenGenomicRun *run =
        [([[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"GRCh38"
                        platform:platform
                      sampleName:@"HG002"
                       positions:posD
                mappingQualities:mqD
                           flags:flD
                       sequences:seqData
                       qualities:qualData
                         offsets:offD
                         lengths:lenD
                          cigars:cigars
                       readNames:readNames
                 mateChromosomes:mateChroms
                   matePositions:mpD
                 templateLengths:tlD
                     chromosomes:chroms
               signalCompression:TTIOCompressionZlib
            signalCodecOverrides:@{}]) copyWithOptLegacyWholeChannel:YES];

    run.referenceChromSeqs = @{ @"22": m97Ref() };
    run.embedReference = YES;
    return run;
}

/** Raw refdiff_v2 blob bytes of the legacy whole-channel file at
 *  @p cpath, or nil. */
static NSData *m97LegacyRefDiffBlob(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return nil;
    hid_t did = H5Dopen2(
        f, "study/genomic_runs/genomic_0001/signal_channels/sequences/refdiff_v2",
        H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return nil; }
    hid_t sp = H5Dget_space(did);
    hssize_t n = H5Sget_simple_extent_npoints(sp);
    H5Sclose(sp);
    NSMutableData *out = nil;
    if (n > 0) {
        out = [NSMutableData dataWithLength:(NSUInteger)n];
        if (H5Dread(did, H5T_NATIVE_UINT8, H5S_ALL, H5S_ALL, H5P_DEFAULT,
                    out.mutableBytes) < 0)
            out = nil;
    }
    H5Dclose(did);
    H5Fclose(f);
    return out;
}

static uint32_t m97NSlices(NSData *blob)
{
    if (blob.length < 12) return 0;
    const uint8_t *b = (const uint8_t *)blob.bytes;
    return (uint32_t)b[8] | ((uint32_t)b[9] << 8)
         | ((uint32_t)b[10] << 16) | ((uint32_t)b[11] << 24);
}

// ── QUALITY_BINNED platform guard ─────────────────────────────────

static void m97PlatformPredicate(void)
{
    PASS(TTIOQualityBinnedAllowedForPlatform(nil),
         "M97 guard: nil platform allowed");
    PASS(TTIOQualityBinnedAllowedForPlatform(@""),
         "M97 guard: empty platform allowed");
    PASS(TTIOQualityBinnedAllowedForPlatform(@"ILLUMINA"),
         "M97 guard: ILLUMINA allowed");
    PASS(TTIOQualityBinnedAllowedForPlatform(@"IONTORRENT"),
         "M97 guard: IONTORRENT allowed (ont only as a token)");
    PASS(!TTIOQualityBinnedAllowedForPlatform(@"ONT"),
         "M97 guard: ONT rejected");
    PASS(!TTIOQualityBinnedAllowedForPlatform(@"PacBio HiFi"),
         "M97 guard: PacBio HiFi rejected");
    PASS(!TTIOQualityBinnedAllowedForPlatform(@"HIFI"),
         "M97 guard: HIFI rejected");
    PASS(!TTIOQualityBinnedAllowedForPlatform(@"Oxford Nanopore"),
         "M97 guard: Oxford Nanopore rejected");
}

static void m97QualityBinnedGuard(void)
{
    // writeMinimal path: an ONT run with a QUALITY_BINNED qualities
    // override raises before anything is written.
    TTIOWrittenGenomicRun *ont =
        [m97MakeAlignedRun(@"ONT") copyWithSignalCodecOverrides:
            @{@"qualities": @(TTIOCompressionQualityBinned)}];
    NSString *path = m97TmpPath(@"guard");
    m97Rm(path);
    BOOL raised = NO;
    @try {
        NSError *err = nil;
        [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"M97Guard"
                            isaInvestigationId:@"ISA-M97"
                                        msRuns:@{}
                                    genomicRuns:@{@"genomic_0001": ont}
                                identifications:nil
                                quantifications:nil
                              provenanceRecords:nil
                                          error:&err];
    } @catch (NSException *e) {
        raised = [e.name isEqualToString:NSInvalidArgumentException];
    }
    PASS(raised, "M97 guard: writeMinimal rejects QUALITY_BINNED on ONT");
    m97Rm(path);

    // Stream-writer path: rejected at init.
    NSString *url = [NSString stringWithFormat:@"memory://m97-guard-%d", (int)getpid()];
    [TTIOMemoryProvider discardStore:url];
    id<TTIOStorageProvider> mem = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory" error:NULL];
    id<TTIOStorageGroup> study =
        [[mem rootGroupWithError:NULL] createGroupNamed:@"study" error:NULL];
    TTIOGenomicStreamWriterOptions *o = [TTIOGenomicStreamWriterOptions defaultOptions];
    o.platform = @"PacBio HiFi";
    o.signalCodecOverrides = @{@"qualities": @(TTIOCompressionQualityBinned)};
    raised = NO;
    @try {
        (void)[[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study
                                                          runName:@"g"
                                                          options:o];
    } @catch (NSException *e) {
        raised = [e.name isEqualToString:NSInvalidArgumentException];
    }
    PASS(raised, "M97 guard: stream writer rejects QUALITY_BINNED on HiFi");

    // The same override on a short-read platform is accepted.
    o = [TTIOGenomicStreamWriterOptions defaultOptions];
    o.platform = @"ILLUMINA";
    o.signalCodecOverrides = @{@"qualities": @(TTIOCompressionQualityBinned)};
    BOOL ok = YES;
    @try {
        (void)[[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study
                                                          runName:@"g2"
                                                          options:o];
    } @catch (NSException *e) {
        ok = NO;
    }
    PASS(ok, "M97 guard: QUALITY_BINNED accepted on ILLUMINA");
}

// ── @read_role round-trip ─────────────────────────────────────────

static void m97ReadRoleRoundTrip(void)
{
    NSString *path = m97TmpPath(@"role");
    m97Rm(path);
    TTIOWrittenGenomicRun *run = m97MakeAlignedRun(@"PacBio HiFi");
    run.readRole = @"hifi";
    NSError *err = nil;
    PASS([TTIOSpectralDataset writeMinimalToPath:path
                                           title:@"M97Role"
                             isaInvestigationId:@"ISA-M97"
                                         msRuns:@{}
                                     genomicRuns:@{@"genomic_0001": run}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err],
         "M97 read_role: write succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS([gr.readRole isEqualToString:@"hifi"],
         "M97 read_role: accessor returns 'hifi' (got %@)",
         gr.readRole ?: @"<nil>");
    [ds closeFile];
    m97Rm(path);

    // Absent attribute (pre-M97 file shape) reads back as nil.
    m97Rm(path);
    TTIOWrittenGenomicRun *plain = m97MakeAlignedRun(@"ILLUMINA");
    PASS([TTIOSpectralDataset writeMinimalToPath:path
                                           title:@"M97RoleAbsent"
                             isaInvestigationId:@"ISA-M97"
                                         msRuns:@{}
                                     genomicRuns:@{@"genomic_0001": plain}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err],
         "M97 read_role: role-less write succeeds");
    ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readRole == nil,
         "M97 read_role: absent attribute reads back nil");
    [ds closeFile];
    m97Rm(path);

    // blocks_v1 path: the stream writer stamps the attribute from its
    // options.
    NSString *url = [NSString stringWithFormat:@"memory://m97-role-%d", (int)getpid()];
    [TTIOMemoryProvider discardStore:url];
    id<TTIOStorageProvider> mem = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory" error:NULL];
    id<TTIOStorageGroup> study =
        [[mem rootGroupWithError:NULL] createGroupNamed:@"study" error:NULL];
    TTIOWrittenGenomicRun *blockRun = m97MakeAlignedRun(@"ONT");
    blockRun = [blockRun copyWithOptLegacyWholeChannel:NO];
    blockRun.readRole = @"ont_ul";
    TTIOGenomicStreamWriterOptions *o =
        [TTIOGenomicStreamWriterOptions optionsFromRun:blockRun];
    TTIOGenomicStreamWriter *w =
        [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study
                                                    runName:@"g"
                                                    options:o];
    PASS([w appendBatch:blockRun error:&err], "M97 read_role: blocks append");
    PASS([w close:&err], "M97 read_role: blocks close");
    id<TTIOStorageGroup> rg =
        [[study openGroupNamed:@"genomic_runs" error:NULL] openGroupNamed:@"g"
                                                                    error:NULL];
    NSString *role = [rg attributeValueForName:@"read_role" error:NULL];
    PASS([role isEqualToString:@"ont_ul"],
         "M97 read_role: blocks_v1 run attribute is 'ont_ul' (got %@)",
         role ?: @"<nil>");
}

// ── REF_DIFF_V2 slice_bytes through the writer ────────────────────

static void m97SliceBytesThroughWriter(void)
{
    // The blocks encoder carries refDiffSliceBytes into the refdiff
    // codec: a 100-base budget over 40 x 10 bp reads makes 4 slices
    // where the default makes 1.
    NSError *err = nil;
    TTIOWrittenGenomicRun *plain =
        [m97MakeAlignedRun(@"PacBio HiFi") copyWithOptLegacyWholeChannel:NO];
    TTIOBlockBlobs *def = [TTIOGenomicBlocks encodeBlock:plain
                                                 context:[TTIOGenomicWriteContext none]
                                                   error:&err];
    PASS(def != nil, "M97 slice_bytes: default block encode (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    if (!def) return;
    PASS([def.codecs[@"sequences"] integerValue] == TTIOCompressionRefDiffV2,
         "M97 slice_bytes: sequences channel is REF_DIFF_V2");
    PASS(m97NSlices(def.blobs[@"sequences"]) == 1,
         "M97 slice_bytes: default is 1 slice (got %u)",
         m97NSlices(def.blobs[@"sequences"]));

    TTIOWrittenGenomicRun *budgeted =
        [m97MakeAlignedRun(@"PacBio HiFi") copyWithOptLegacyWholeChannel:NO];
    budgeted.refDiffSliceBytes = 100;
    TTIOBlockBlobs *bb = [TTIOGenomicBlocks encodeBlock:budgeted
                                                context:[TTIOGenomicWriteContext none]
                                                  error:&err];
    PASS(bb != nil, "M97 slice_bytes: budgeted block encode");
    if (!bb) return;
    uint32_t nSlices = m97NSlices(bb.blobs[@"sequences"]);
    PASS(nSlices == 4,
         "M97 slice_bytes: 100-base budget makes 4 slices (got %u)", nSlices);

    // Legacy whole-channel writeMinimal path: same knob, and the file
    // round-trips through the ordinary reader.
    NSString *path = m97TmpPath(@"slice");
    m97Rm(path);
    TTIOWrittenGenomicRun *legacy = m97MakeAlignedRun(@"PacBio HiFi");
    legacy.refDiffSliceBytes = 100;
    PASS([TTIOSpectralDataset writeMinimalToPath:path
                                           title:@"M97Slice"
                             isaInvestigationId:@"ISA-M97"
                                         msRuns:@{}
                                     genomicRuns:@{@"genomic_0001": legacy}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err],
         "M97 slice_bytes: legacy write succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    NSData *legacyBlob = m97LegacyRefDiffBlob([path fileSystemRepresentation]);
    PASS(m97NSlices(legacyBlob) == 4,
         "M97 slice_bytes: legacy HDF5 blob carries 4 slices (got %u)",
         m97NSlices(legacyBlob));
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allCorrect = (gr != nil && gr.readCount == 40);
    for (NSUInteger i = 0; allCorrect && i < 40; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (!r || ![r.sequence isEqualToString:@"ACGTACGTAC"]) allCorrect = NO;
    }
    PASS(allCorrect,
         "M97 slice_bytes: budgeted legacy file round-trips 40 reads");
    [ds closeFile];
    m97Rm(path);
}

void testM97LongReadProfile(void);
void testM97LongReadProfile(void)
{
    m97PlatformPredicate();
    m97QualityBinnedGuard();
    m97ReadRoleRoundTrip();
    m97SliceBytesThroughWriter();
}
