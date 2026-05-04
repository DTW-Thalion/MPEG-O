// TestMateInfoV2Dispatch.m — v1.7 Task 14: ObjC writer/reader dispatch.
//
// Mirrors:
//   python/tests/test_mate_info_v2_dispatch.py     (Task 12)
//   java/src/test/java/.../MateInfoV2DispatchTest.java (Task 13)
//
// v1.0 reset: the inline-mate-info v2 opt-out flag was removed. The
// writer always emits the inline_v2 codec when libttio_rans is linked.
//
// Verifies:
//   * Default (nativeAvailable) the writer encodes via inline_v2
//     (HDF5 group with @compression=13 on inline_v2 ds).
//   * signalCodecOverrides[mate_info_*] raise NSInvalidArgumentException
//     because v2 is always active when the native lib is linked.
//   * Full round-trip via TTIOSpectralDataset returns correct mate fields.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "Testing.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Codecs/TTIOMateInfoV2.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

// ── Shared fixture ───────────────────────────────────────────────────────────

static NSString *v2dTmpPath(NSString *tag)
{
    return [NSString stringWithFormat:@"/tmp/ttio_mid_dispatch_%d_%@",
            (int)getpid(), tag];
}

static void v2dRm(NSString *p)
{
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

/** Build a small 3-read genomic run suitable for mate-info dispatch tests.
 *  Chromosomes: chr1/chr1/chr2.  Mates: chr1/chr2/* (unmapped). */
static TTIOWrittenGenomicRun *v2dMakeRun(NSDictionary *overrides)
{
    NSUInteger n = 3;
    NSUInteger L = 8;
    NSArray *chroms     = @[@"chr1", @"chr1", @"chr2"];
    NSArray *mateChroms = @[@"chr1", @"chr2", @"*"];

    int64_t  pos[3]   = {100, 200, 300};
    uint8_t  mq[3]    = {60, 60, 60};
    uint32_t fl[3]    = {0x0003, 0x0003, 0x0001};
    int64_t  mp[3]    = {150, 250, -1};
    int32_t  tl[3]    = {100, -200, 0};

    NSMutableData *seqData  = [NSMutableData dataWithCapacity:n * L];
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    for (NSUInteger i = 0; i < n; i++)
        [seqData appendBytes:"ACGTACGT" length:L];
    memset(qualData.mutableBytes, 30, n * L);

    uint64_t off[3]   = {0, 8, 16};
    uint32_t len[3]   = {8, 8, 8};

    NSArray *cigars    = @[@"8M", @"4M4M", @"2S6M"];
    NSArray *readNames = @[@"r_aaa", @"r_bbb", @"r_ccc"];

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"GRCh38"
                        platform:@"ILLUMINA"
                      sampleName:@"NA12878"
                       positions:[NSData dataWithBytes:pos length:sizeof(pos)]
                mappingQualities:[NSData dataWithBytes:mq length:sizeof(mq)]
                           flags:[NSData dataWithBytes:fl length:sizeof(fl)]
                       sequences:seqData
                       qualities:qualData
                         offsets:[NSData dataWithBytes:off length:sizeof(off)]
                         lengths:[NSData dataWithBytes:len length:sizeof(len)]
                          cigars:cigars
                       readNames:readNames
                 mateChromosomes:mateChroms
                   matePositions:[NSData dataWithBytes:mp length:sizeof(mp)]
                 templateLengths:[NSData dataWithBytes:tl length:sizeof(tl)]
                     chromosomes:chroms
               signalCompression:TTIOCompressionNone
            signalCodecOverrides:(overrides ?: @{})];
    return run;
}

static BOOL v2dWrite(NSString *path, TTIOWrittenGenomicRun *run, NSError **err)
{
    return [TTIOSpectralDataset writeMinimalToPath:path
                                             title:@"MateInfoV2Dispatch"
                               isaInvestigationId:@"ISA-MIV2D"
                                           msRuns:@{}
                                       genomicRuns:@{@"genomic_0001": run}
                                   identifications:nil
                                   quantifications:nil
                                 provenanceRecords:nil
                                             error:err];
}

// ── Helper: HDF5 low-level inspection ────────────────────────────────────────

/** Returns the H5G_obj_t for "study/genomic_runs/genomic_0001/
 *  signal_channels/mate_info" inside the file at path, or -1 on error. */
static H5G_obj_t v2dMateInfoObjectType(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return (H5G_obj_t)-1;
    H5O_info_t oinfo;
    memset(&oinfo, 0, sizeof(oinfo));
    herr_t s = H5Oget_info_by_name(f,
                    "study/genomic_runs/genomic_0001/signal_channels/mate_info",
                    &oinfo, H5P_DEFAULT);
    H5Fclose(f);
    if (s < 0) return (H5G_obj_t)-1;
    return (H5G_obj_t)oinfo.type;  // H5O_TYPE_DATASET or H5O_TYPE_GROUP
}

/** Returns the @compression attribute on inline_v2, or 255 if absent/error. */
static uint8_t v2dInlineV2CompressionAttr(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 255;
    hid_t did = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/mate_info/inline_v2",
        H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return 255; }
    uint8_t v = 254;  // sentinel = absent
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

// ── Test 1: default encode uses inline_v2 ────────────────────────────────────

static void testDefaultWritesInlineV2(void)
{
    NSString *path = v2dTmpPath(@"default.tio");
    v2dRm(path);

    TTIOWrittenGenomicRun *run = v2dMakeRun(nil);
    NSError *err = nil;
    PASS(v2dWrite(path, run, &err), "MIV2Dispatch #1: write succeeds (native)");

    // HDF5 inspection: mate_info must be a GROUP (not a dataset).
    H5G_obj_t ot = v2dMateInfoObjectType(path.fileSystemRepresentation);
    PASS(ot == H5O_TYPE_GROUP,
         "MIV2Dispatch #1: signal_channels/mate_info is a GROUP (inline_v2)");

    // The inline_v2 dataset must carry @compression == 13.
    uint8_t cid = v2dInlineV2CompressionAttr(path.fileSystemRepresentation);
    PASS(cid == (uint8_t)TTIOCompressionMateInlineV2,
         "MIV2Dispatch #1: inline_v2 @compression == 13 (got %u)", (unsigned)cid);

    v2dRm(path);
}

// ── Test 2: mate_info_* overrides rejected (v2 always active) ────────────────

static void testSignalCodecOverridesRejectedWhenV2Active(void)
{
    NSString *path = v2dTmpPath(@"reject.tio");
    v2dRm(path);

    NSDictionary *overrides = @{@"mate_info_chrom": @(TTIOCompressionRansOrder1)};
    TTIOWrittenGenomicRun *run = v2dMakeRun(overrides);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        v2dWrite(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised, "MIV2Dispatch #2: mate_info_* override raises NSException when v2 active");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "MIV2Dispatch #2: exception is NSInvalidArgumentException");

    v2dRm(path);
}

// ── Test 3: full round-trip via SpectralDataset (default = v2) ───────────────

static void testV2RoundTripDefault(void)
{
    NSString *path = v2dTmpPath(@"rt.tio");
    v2dRm(path);

    TTIOWrittenGenomicRun *run = v2dMakeRun(nil);
    NSError *err = nil;
    PASS(v2dWrite(path, run, &err), "MIV2Dispatch #3: write succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "MIV2Dispatch #3: dataset re-opens");

    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 3, "MIV2Dispatch #3: 3 reads round-trip");

    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    TTIOAlignedRead *r1 = [gr readAtIndex:1 error:&err];
    TTIOAlignedRead *r2 = [gr readAtIndex:2 error:&err];
    PASS(r0 && r1 && r2, "MIV2Dispatch #3: all 3 reads materialise");

    // Mate chromosomes: input was @[@"chr1", @"chr2", @"*"].
    // v2 encodes chr1→id0, chr2→id1, *→-1.  Decoder returns the
    // chromosome name string (or "*" for -1).
    PASS([r0.mateChromosome isEqualToString:@"chr1"],
         "MIV2Dispatch #3: r0.mateChromosome == 'chr1'");
    PASS([r1.mateChromosome isEqualToString:@"chr2"],
         "MIV2Dispatch #3: r1.mateChromosome == 'chr2'");
    PASS([r2.mateChromosome isEqualToString:@"*"],
         "MIV2Dispatch #3: r2.mateChromosome == '*' (unmapped)");

    // Mate positions: {150, 250, -1}
    PASS(r0.matePosition == 150 && r1.matePosition == 250 && r2.matePosition == -1,
         "MIV2Dispatch #3: matePositions round-trip");

    // Template lengths: {100, -200, 0}
    PASS(r0.templateLength == 100 && r1.templateLength == -200
         && r2.templateLength == 0,
         "MIV2Dispatch #3: templateLengths round-trip");

    [ds closeFile];
    v2dRm(path);
}

// ── Public entry point ────────────────────────────────────────────────────────

void testMateInfoV2Dispatch(void)
{
    if (![TTIOMateInfoV2 nativeAvailable]) {
        // Honest skip — propagates to enclosing START_SET / END_SET in
        // TTIOTestRunner.m as "Skipped set:" rather than a vacuous PASS.
        SKIP("libttio_rans not linked — v2 dispatch tests require native lib");
    }
    testDefaultWritesInlineV2();
    testSignalCodecOverridesRejectedWhenV2Active();
    testV2RoundTripDefault();
}
