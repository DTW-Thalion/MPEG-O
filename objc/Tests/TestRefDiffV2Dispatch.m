// TestRefDiffV2Dispatch.m — v1.8 #11 Task 14: ObjC writer/reader dispatch.
//
// Mirrors:
//   python/tests/test_ref_diff_v2_dispatch.py  (Task 12)
//   java/.../RefDiffV2DispatchTest.java         (Task 13)
//
// Verifies:
//   1. Default v1.8 write produces signal_channels/sequences as a GROUP
//      containing a refdiff_v2 child dataset @compression=14.
//   2. optDisableRefDiffV2 = YES falls back to v1 flat dataset
//      (sequences is a dataset, not a group).
//   3. optDisableRefDiffV2 = YES + no reference: sequences is a BASE_PACK
//      flat dataset (@compression=6).
//   4. Full round-trip via TTIOSpectralDataset (default path): sequences
//      round-trip correct.
//   5. Full round-trip via TTIOSpectralDataset (opt-out path): sequences
//      round-trip correct.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "Testing.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Codecs/TTIORefDiffV2.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

// ── Shared fixture ────────────────────────────────────────────────────────────

static NSString *rdv2dTmpPath(NSString *tag)
{
    return [NSString stringWithFormat:@"/tmp/ttio_rdv2_dispatch_%d_%@.tio",
            (int)getpid(), tag];
}

static void rdv2dRm(NSString *p)
{
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

/** Reference sequence: 1000 × "ACGTACGTAC" (10 000 bp). */
static NSData *rdv2dRef(void)
{
    NSData *unit = [@"ACGTACGTAC" dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *d = [NSMutableData data];
    for (int i = 0; i < 1000; i++) [d appendData:unit];
    return d;
}

/** Build a minimal 5-read single-chromosome run for dispatch tests.
 *  All reads aligned to chr22, 10 bp each, cigar "10M", positions 1-5.
 *  referenceChromSeqs is set when embedRef == YES. */
static TTIOWrittenGenomicRun *rdv2dMakeRun(BOOL disableRefDiffV2,
                                            BOOL hasReference)
{
    NSUInteger n = 5;
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
        pos[i] = (int64_t)(i + 1);
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
        [[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"GRCh38"
                        platform:@"ILLUMINA"
                      sampleName:@"NA12878"
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
            signalCodecOverrides:@{}];

    run.optDisableRefDiffV2 = disableRefDiffV2;

    if (hasReference) {
        run.referenceChromSeqs = @{ @"22": rdv2dRef() };
        // Embed the reference so the reader can resolve it for decode.
        run.embedReference = YES;
    }

    return run;
}

static BOOL rdv2dWrite(NSString *path, TTIOWrittenGenomicRun *run,
                        NSError **err)
{
    return [TTIOSpectralDataset writeMinimalToPath:path
                                             title:@"RefDiffV2Dispatch"
                               isaInvestigationId:@"ISA-RDV2D"
                                           msRuns:@{}
                                       genomicRuns:@{@"genomic_0001": run}
                                   identifications:nil
                                   quantifications:nil
                                 provenanceRecords:nil
                                             error:err];
}

// ── HDF5 inspection helpers ───────────────────────────────────────────────────

/** Returns H5O_TYPE_GROUP or H5O_TYPE_DATASET for
 *  study/genomic_runs/genomic_0001/signal_channels/sequences, or -1 on
 *  error. */
static int rdv2dSequencesObjectType(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return -1;
    H5O_info_t oinfo;
    memset(&oinfo, 0, sizeof(oinfo));
    herr_t s = H5Oget_info_by_name(
        f, "study/genomic_runs/genomic_0001/signal_channels/sequences",
        &oinfo, H5P_DEFAULT);
    H5Fclose(f);
    if (s < 0) return -1;
    return (int)oinfo.type;
}

/** Returns the @compression attribute on
 *  .../signal_channels/sequences/refdiff_v2, or 255 on error. */
static uint8_t rdv2dRefDiffV2CompressionAttr(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 255;
    hid_t did = H5Dopen2(
        f, "study/genomic_runs/genomic_0001/signal_channels/sequences/refdiff_v2",
        H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return 255; }
    uint8_t v = 254;
    if (H5Aexists(did, "compression") > 0) {
        hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
        if (aid >= 0) {
            H5Aread(aid, H5T_NATIVE_UINT8, &v);
            H5Aclose(aid);
        }
    }
    H5Dclose(did);
    H5Fclose(f);
    return v;
}

/** Returns the @compression attribute on the flat
 *  .../signal_channels/sequences dataset, or 255 on error. */
static uint8_t rdv2dFlatSequencesCompressionAttr(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 255;
    hid_t did = H5Dopen2(
        f, "study/genomic_runs/genomic_0001/signal_channels/sequences",
        H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return 255; }
    uint8_t v = 254;
    if (H5Aexists(did, "compression") > 0) {
        hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
        if (aid >= 0) {
            H5Aread(aid, H5T_NATIVE_UINT8, &v);
            H5Aclose(aid);
        }
    }
    H5Dclose(did);
    H5Fclose(f);
    return v;
}

// ── Test 1: default write produces refdiff_v2 group layout ───────────────────

static void testRefDiffV2DispatchDefaultWritesGroup(void)
{
    if (![TTIORefDiffV2 nativeAvailable]) {
        PASS(1, "RefDiffV2Dispatch #1: nativeAvailable=NO — skip");
        return;
    }

    NSString *path = rdv2dTmpPath(@"default");
    rdv2dRm(path);

    TTIOWrittenGenomicRun *run = rdv2dMakeRun(NO, YES);
    NSError *err = nil;
    PASS(rdv2dWrite(path, run, &err),
         "RefDiffV2Dispatch #1: write succeeds (native, v2 default)");

    int ot = rdv2dSequencesObjectType(path.fileSystemRepresentation);
    PASS(ot == (int)H5O_TYPE_GROUP,
         "RefDiffV2Dispatch #1: signal_channels/sequences is a GROUP (refdiff_v2)");

    uint8_t cid = rdv2dRefDiffV2CompressionAttr(path.fileSystemRepresentation);
    PASS(cid == (uint8_t)TTIOCompressionRefDiffV2,
         "RefDiffV2Dispatch #1: refdiff_v2 @compression == 14 (got %u)",
         (unsigned)cid);

    rdv2dRm(path);
}

// ── Test 2: opt-out falls back to v1 flat dataset ────────────────────────────

static void testRefDiffV2DispatchOptOutWritesFlatDataset(void)
{
    NSString *path = rdv2dTmpPath(@"optout");
    rdv2dRm(path);

    TTIOWrittenGenomicRun *run = rdv2dMakeRun(YES, YES);  // opt-out = YES
    NSError *err = nil;
    PASS(rdv2dWrite(path, run, &err),
         "RefDiffV2Dispatch #2: write succeeds (v1 opt-out)");

    int ot = rdv2dSequencesObjectType(path.fileSystemRepresentation);
    PASS(ot == (int)H5O_TYPE_DATASET,
         "RefDiffV2Dispatch #2: signal_channels/sequences is a DATASET (v1 flat)");

    // v1 REF_DIFF path: @compression should be 9 (REF_DIFF) since referenceChromSeqs set.
    uint8_t cid = rdv2dFlatSequencesCompressionAttr(path.fileSystemRepresentation);
    PASS(cid == (uint8_t)TTIOCompressionRefDiff,
         "RefDiffV2Dispatch #2: flat sequences @compression == 9 (v1 REF_DIFF, got %u)",
         (unsigned)cid);

    rdv2dRm(path);
}

// ── Test 3: opt-out + no reference → BASE_PACK flat dataset ─────────────────

static void testRefDiffV2DispatchNoRefWritesBasePack(void)
{
    NSString *path = rdv2dTmpPath(@"noref");
    rdv2dRm(path);

    TTIOWrittenGenomicRun *run = rdv2dMakeRun(YES, NO);  // opt-out, no ref
    // Ensure the codec override selects REF_DIFF so the v1 path is exercised
    // with no-ref fallback (Q5b = C → BASE_PACK).
    // Without codec override and without reference, the run uses Zlib
    // (no v1.5 auto-default since no referenceChromSeqs). Let's force
    // the REF_DIFF override so the fallback is observable.
    // Actually with opt-out + no reference the v1.5 auto-default also
    // won't fire (nil referenceChromSeqs). The writer uses Zlib.
    // Use a signalCodecOverride of REF_DIFF to trigger the v1 path + fallback.
    TTIOWrittenGenomicRun *runWithOverride =
        [[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:run.acquisitionMode
                    referenceUri:run.referenceUri
                        platform:run.platform
                      sampleName:run.sampleName
                       positions:run.positionsData
                mappingQualities:run.mappingQualitiesData
                           flags:run.flagsData
                       sequences:run.sequencesData
                       qualities:run.qualitiesData
                         offsets:run.offsetsData
                         lengths:run.lengthsData
                          cigars:run.cigars
                       readNames:run.readNames
                 mateChromosomes:run.mateChromosomes
                   matePositions:run.matePositionsData
                 templateLengths:run.templateLengthsData
                     chromosomes:run.chromosomes
               signalCompression:TTIOCompressionZlib
            signalCodecOverrides:@{ @"sequences": @(TTIOCompressionRefDiff) }];
    runWithOverride.optDisableRefDiffV2 = YES;
    // No referenceChromSeqs → v1 fallback → BASE_PACK.

    NSError *err = nil;
    PASS(rdv2dWrite(path, runWithOverride, &err),
         "RefDiffV2Dispatch #3: write succeeds (REF_DIFF override + no ref)");

    int ot = rdv2dSequencesObjectType(path.fileSystemRepresentation);
    PASS(ot == (int)H5O_TYPE_DATASET,
         "RefDiffV2Dispatch #3: signal_channels/sequences is a DATASET (fallback)");

    uint8_t cid = rdv2dFlatSequencesCompressionAttr(path.fileSystemRepresentation);
    PASS(cid == (uint8_t)TTIOCompressionBasePack,
         "RefDiffV2Dispatch #3: flat sequences @compression == 6 (BASE_PACK fallback, got %u)",
         (unsigned)cid);

    rdv2dRm(path);
}

// ── Test 4: full round-trip (default v2 path) ─────────────────────────────────

static void testRefDiffV2DispatchRoundTripV2(void)
{
    if (![TTIORefDiffV2 nativeAvailable]) {
        PASS(1, "RefDiffV2Dispatch #4: nativeAvailable=NO — skip");
        return;
    }

    NSString *path = rdv2dTmpPath(@"rt_v2");
    rdv2dRm(path);

    TTIOWrittenGenomicRun *run = rdv2dMakeRun(NO, YES);
    NSError *err = nil;
    PASS(rdv2dWrite(path, run, &err), "RefDiffV2Dispatch #4: write succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "RefDiffV2Dispatch #4: dataset re-opens");

    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 5, "RefDiffV2Dispatch #4: 5 reads round-trip");

    BOOL allCorrect = YES;
    NSString *firstSeq = nil;
    NSError *firstErr = nil;
    for (NSUInteger i = 0; i < 5; i++) {
        NSError *rErr = nil;
        TTIOAlignedRead *r = [gr readAtIndex:i error:&rErr];
        if (i == 0) { firstSeq = r ? r.sequence : nil; firstErr = rErr; }
        if (!r || ![r.sequence isEqualToString:@"ACGTACGTAC"]) {
            allCorrect = NO;
            break;
        }
    }
    PASS(allCorrect,
         "RefDiffV2Dispatch #4: all 5 reads decode to 'ACGTACGTAC' (v2 round-trip) "
         "[r0=%@ err=%@]",
         firstSeq ?: @"<nil>",
         firstErr.localizedDescription ?: @"<no err>");

    [ds closeFile];
    rdv2dRm(path);
}

// ── Test 5: full round-trip (opt-out v1 path) ─────────────────────────────────

static void testRefDiffV2DispatchRoundTripV1(void)
{
    NSString *path = rdv2dTmpPath(@"rt_v1");
    rdv2dRm(path);

    TTIOWrittenGenomicRun *run = rdv2dMakeRun(YES, YES);  // opt-out
    NSError *err = nil;
    PASS(rdv2dWrite(path, run, &err),
         "RefDiffV2Dispatch #5: write succeeds (v1 opt-out)");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "RefDiffV2Dispatch #5: dataset re-opens");

    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 5, "RefDiffV2Dispatch #5: 5 reads round-trip");

    BOOL allCorrect = YES;
    NSString *firstSeq = nil;
    NSError *firstErr = nil;
    for (NSUInteger i = 0; i < 5; i++) {
        NSError *rErr = nil;
        TTIOAlignedRead *r = [gr readAtIndex:i error:&rErr];
        if (i == 0) { firstSeq = r ? r.sequence : nil; firstErr = rErr; }
        if (!r || ![r.sequence isEqualToString:@"ACGTACGTAC"]) {
            allCorrect = NO;
            break;
        }
    }
    PASS(allCorrect,
         "RefDiffV2Dispatch #5: all 5 reads decode to 'ACGTACGTAC' (v1 opt-out round-trip) "
         "[r0=%@ err=%@]",
         firstSeq ?: @"<nil>",
         firstErr.localizedDescription ?: @"<no err>");

    [ds closeFile];
    rdv2dRm(path);
}

// ── Public entry point ────────────────────────────────────────────────────────

void testRefDiffV2Dispatch(void);
void testRefDiffV2Dispatch(void)
{
    testRefDiffV2DispatchDefaultWritesGroup();
    testRefDiffV2DispatchOptOutWritesFlatDataset();
    testRefDiffV2DispatchNoRefWritesBasePack();
    testRefDiffV2DispatchRoundTripV2();
    testRefDiffV2DispatchRoundTripV1();
}
