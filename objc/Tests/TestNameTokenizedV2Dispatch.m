// TestNameTokenizedV2Dispatch.m — v1.8 #11 ch3 Task 14: ObjC writer/reader dispatch.
//
// Mirrors:
//   python/tests/test_name_tok_v2_dispatch.py  (Task 12)
//   java/.../NameTokenizedV2DispatchTest.java   (Task 13)
//
// Verifies:
//   1. Default v1.8 write produces signal_channels/read_names flat dataset
//      with @compression == 15 (NAME_TOKENIZED_V2).
//   2. optDisableNameTokenizedV2 = YES + no override falls back to M82
//      compound layout (no @compression attribute).
//   3. signalCodecOverrides[@"read_names"] = NAME_TOKENIZED writes v1
//      flat dataset @compression == 8 regardless of opt flag.
//   4. v1 opt-out round-trip (M82 compound): names recovered.
//   5. v2 default round-trip: names recovered byte-exact.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "Testing.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Codecs/TTIONameTokenizerV2.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

// ── Shared fixture ────────────────────────────────────────────────────────────

static NSString *ntv2dTmpPath(NSString *tag)
{
    return [NSString stringWithFormat:@"/tmp/ttio_ntv2_dispatch_%d_%@.tio",
            (int)getpid(), tag];
}

static void ntv2dRm(NSString *p)
{
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

/** Build a minimal 100-read run with Illumina-style structured names that
 *  exercise the v2 column-aware tokeniser. Disables refdiff_v2 + inline_v2
 *  so the test is focused on read_names dispatch. */
static TTIOWrittenGenomicRun *ntv2dMakeRun(BOOL optDisableV2,
                                            NSDictionary *codecOverrides)
{
    NSUInteger n = 100;
    NSUInteger L = 50;

    NSMutableData *seqData  = [NSMutableData dataWithCapacity:n * L];
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    for (NSUInteger i = 0; i < n; i++) {
        for (NSUInteger j = 0; j < L; j++) {
            uint8_t b = (uint8_t)("ACGT"[j % 4]);
            [seqData appendBytes:&b length:1];
        }
    }
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
        pos[i] = (int64_t)(i * 1000 + 1);
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
        [chroms     addObject:@"chr1"];
        [mateChroms addObject:@"*"];
        [cigars     addObject:[NSString stringWithFormat:@"%luM", (unsigned long)L]];
        [readNames  addObject:[NSString stringWithFormat:
                               @"INSTR:RUN:1:%lu:%lu:%lu",
                               (unsigned long)(i / 4),
                               (unsigned long)(i % 4),
                               (unsigned long)(i * 100)]];
    }

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"GRCh38.dispatch_test"
                        platform:@"ILLUMINA"
                      sampleName:@"NT_DISP_TEST"
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
               signalCompression:TTIOCompressionNone
            signalCodecOverrides:(codecOverrides ?: @{})];

    // Focus on read_names: opt out of inline_v2 + refdiff_v2 paths.
    run.optDisableInlineMateInfoV2 = YES;
    run.optDisableRefDiffV2        = YES;
    run.optDisableNameTokenizedV2  = optDisableV2;

    return run;
}

static BOOL ntv2dWrite(NSString *path, TTIOWrittenGenomicRun *run,
                        NSError **err)
{
    return [TTIOSpectralDataset writeMinimalToPath:path
                                             title:@"NameTokenizedV2Dispatch"
                               isaInvestigationId:@"ISA-NTV2D"
                                           msRuns:@{}
                                       genomicRuns:@{@"genomic_0001": run}
                                   identifications:nil
                                   quantifications:nil
                                 provenanceRecords:nil
                                             error:err];
}

// ── HDF5 inspection helpers ───────────────────────────────────────────────────

/** Returns H5O_TYPE_GROUP or H5O_TYPE_DATASET for
 *  study/genomic_runs/genomic_0001/signal_channels/read_names, or -1 on
 *  error. */
static int ntv2dReadNamesObjectType(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return -1;
    H5O_info_t oinfo;
    memset(&oinfo, 0, sizeof(oinfo));
    herr_t s = H5Oget_info_by_name(
        f, "study/genomic_runs/genomic_0001/signal_channels/read_names",
        &oinfo, H5P_DEFAULT);
    H5Fclose(f);
    if (s < 0) return -1;
    return (int)oinfo.type;
}

/** Returns the @compression attribute on the read_names dataset, or 254
 *  if the attribute is absent, or 255 on open error. */
static uint8_t ntv2dReadNamesCompressionAttr(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 255;
    hid_t did = H5Dopen2(
        f, "study/genomic_runs/genomic_0001/signal_channels/read_names",
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

/** Returns YES iff the read_names dataset has UInt8 elements (codec
 *  schema-lift); NO if it's a compound (M82). */
static BOOL ntv2dReadNamesIsUInt8(const char *cpath)
{
    hid_t f = H5Fopen(cpath, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return NO;
    hid_t did = H5Dopen2(
        f, "study/genomic_runs/genomic_0001/signal_channels/read_names",
        H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return NO; }
    hid_t tid = H5Dget_type(did);
    BOOL isUInt8 = (H5Tequal(tid, H5T_NATIVE_UINT8) > 0);
    H5Tclose(tid);
    H5Dclose(did);
    H5Fclose(f);
    return isUInt8;
}

// ── Test 1: default write produces NAME_TOKENIZED_V2 dataset ─────────────────

static void testNameTokV2DispatchDefaultWritesV2(void)
{
    NSString *path = ntv2dTmpPath(@"default");
    ntv2dRm(path);

    TTIOWrittenGenomicRun *run = ntv2dMakeRun(NO, nil);
    NSError *err = nil;
    PASS(ntv2dWrite(path, run, &err),
         "NameTokV2Dispatch #1: write succeeds (native, v2 default) [err=%@]",
         err.localizedDescription ?: @"<nil>");

    int ot = ntv2dReadNamesObjectType(path.fileSystemRepresentation);
    PASS(ot == (int)H5O_TYPE_DATASET,
         "NameTokV2Dispatch #1: read_names is a flat DATASET (got %d)", ot);

    PASS(ntv2dReadNamesIsUInt8(path.fileSystemRepresentation),
         "NameTokV2Dispatch #1: read_names dtype is UInt8 (codec lift)");

    uint8_t cid = ntv2dReadNamesCompressionAttr(path.fileSystemRepresentation);
    PASS(cid == (uint8_t)TTIOCompressionNameTokenizedV2,
         "NameTokV2Dispatch #1: read_names @compression == 15 (got %u)",
         (unsigned)cid);

    ntv2dRm(path);
}

// ── Test 2: opt-out + no override falls back to M82 compound ─────────────────

static void testNameTokV2DispatchOptOutWritesV1(void)
{
    NSString *path = ntv2dTmpPath(@"optout");
    ntv2dRm(path);

    TTIOWrittenGenomicRun *run = ntv2dMakeRun(YES, nil);
    NSError *err = nil;
    PASS(ntv2dWrite(path, run, &err),
         "NameTokV2Dispatch #2: write succeeds (opt-out, no override) [err=%@]",
         err.localizedDescription ?: @"<nil>");

    int ot = ntv2dReadNamesObjectType(path.fileSystemRepresentation);
    PASS(ot == (int)H5O_TYPE_DATASET,
         "NameTokV2Dispatch #2: read_names is a DATASET (M82 compound)");

    // M82 compound: not uint8, no @compression attribute.
    PASS(!ntv2dReadNamesIsUInt8(path.fileSystemRepresentation),
         "NameTokV2Dispatch #2: opt-out without override remains compound, "
         "not lifted to uint8");

    uint8_t cid = ntv2dReadNamesCompressionAttr(path.fileSystemRepresentation);
    PASS(cid == 254 /* attr absent */,
         "NameTokV2Dispatch #2: M82 compound has no @compression attribute (got %u)",
         (unsigned)cid);

    ntv2dRm(path);
}

// ── Test 3: explicit signal_codec_overrides honoured ─────────────────────────

static void testNameTokV2DispatchOverrideRespected(void)
{
    NSString *path = ntv2dTmpPath(@"override_v1");
    ntv2dRm(path);

    // Explicit override → v1 layout regardless of opt flag.
    TTIOWrittenGenomicRun *run = ntv2dMakeRun(NO,
        @{ @"read_names": @(TTIOCompressionNameTokenized) });
    NSError *err = nil;
    PASS(ntv2dWrite(path, run, &err),
         "NameTokV2Dispatch #3: write succeeds (v1 explicit override) [err=%@]",
         err.localizedDescription ?: @"<nil>");

    int ot = ntv2dReadNamesObjectType(path.fileSystemRepresentation);
    PASS(ot == (int)H5O_TYPE_DATASET,
         "NameTokV2Dispatch #3: read_names is a flat DATASET");

    PASS(ntv2dReadNamesIsUInt8(path.fileSystemRepresentation),
         "NameTokV2Dispatch #3: explicit v1 override produces UInt8 dataset");

    uint8_t cid = ntv2dReadNamesCompressionAttr(path.fileSystemRepresentation);
    PASS(cid == (uint8_t)TTIOCompressionNameTokenized,
         "NameTokV2Dispatch #3: read_names @compression == 8 under explicit "
         "v1 override (got %u)", (unsigned)cid);

    ntv2dRm(path);
}

// ── Test 4: v1 opt-out round-trip (M82 compound) ─────────────────────────────

static void testNameTokV2DispatchRoundTripV1(void)
{
    NSString *path = ntv2dTmpPath(@"rt_v1");
    ntv2dRm(path);

    TTIOWrittenGenomicRun *run = ntv2dMakeRun(YES, nil);
    NSArray *expectedNames = [run.readNames copy];
    NSError *err = nil;
    PASS(ntv2dWrite(path, run, &err),
         "NameTokV2Dispatch #4: write succeeds (v1 opt-out)");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "NameTokV2Dispatch #4: dataset re-opens");

    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 100,
         "NameTokV2Dispatch #4: 100 reads round-trip");

    BOOL allCorrect = YES;
    NSString *firstName = nil;
    for (NSUInteger i = 0; i < 100; i++) {
        NSError *rErr = nil;
        TTIOAlignedRead *r = [gr readAtIndex:i error:&rErr];
        if (i == 0) firstName = r ? r.readName : nil;
        if (!r || ![r.readName isEqualToString:expectedNames[i]]) {
            allCorrect = NO;
            break;
        }
    }
    PASS(allCorrect,
         "NameTokV2Dispatch #4: all 100 read names round-trip (v1 opt-out) "
         "[r0=%@]", firstName ?: @"<nil>");

    [ds closeFile];
    ntv2dRm(path);
}

// ── Test 5: v2 default round-trip ─────────────────────────────────────────────

static void testNameTokV2DispatchRoundTripV2(void)
{
    NSString *path = ntv2dTmpPath(@"rt_v2");
    ntv2dRm(path);

    TTIOWrittenGenomicRun *run = ntv2dMakeRun(NO, nil);
    NSArray *expectedNames = [run.readNames copy];
    NSError *err = nil;
    PASS(ntv2dWrite(path, run, &err),
         "NameTokV2Dispatch #5: write succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "NameTokV2Dispatch #5: dataset re-opens");

    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 100,
         "NameTokV2Dispatch #5: 100 reads round-trip");

    BOOL allCorrect = YES;
    NSString *firstName = nil;
    NSError *firstErr = nil;
    for (NSUInteger i = 0; i < 100; i++) {
        NSError *rErr = nil;
        TTIOAlignedRead *r = [gr readAtIndex:i error:&rErr];
        if (i == 0) { firstName = r ? r.readName : nil; firstErr = rErr; }
        if (!r || ![r.readName isEqualToString:expectedNames[i]]) {
            allCorrect = NO;
            break;
        }
    }
    PASS(allCorrect,
         "NameTokV2Dispatch #5: all 100 read names round-trip (v2 default) "
         "[r0=%@ err=%@]",
         firstName ?: @"<nil>",
         firstErr.localizedDescription ?: @"<no err>");

    [ds closeFile];
    ntv2dRm(path);
}

// ── Public entry point ────────────────────────────────────────────────────────

void testNameTokenizedV2Dispatch(void);
void testNameTokenizedV2Dispatch(void)
{
    if (![TTIONameTokenizerV2 nativeAvailable]) {
        // Honest skip via START_SET / END_SET in TTIOTestRunner.m.
        SKIP("libttio_rans not linked — v2 dispatch tests require native lib");
    }
    testNameTokV2DispatchDefaultWritesV2();
    testNameTokV2DispatchOptOutWritesV1();
    testNameTokV2DispatchOverrideRespected();
    testNameTokV2DispatchRoundTripV1();
    testNameTokV2DispatchRoundTripV2();
}
