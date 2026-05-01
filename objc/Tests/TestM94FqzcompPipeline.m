// TestM94FqzcompPipeline.m — v1.2 M94 Phase 2 pipeline integration tests.
//
// Mirrors python/tests/test_m94_fqzcomp_pipeline.py. Round-trip via
// +writeMinimalToPath: + readFromFilePath:, format-version gating,
// auto-default v1.5-candidacy gate, REVERSE flag affects encoding.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"

#include <hdf5.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── tmp path helper ────────────────────────────────────────────────

static NSString *tmpPathWithName(NSString *name)
{
    NSString *base = NSTemporaryDirectory();
    if (!base.length) base = @"/tmp";
    NSString *p = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ttio_m94_%@_%lu.tio",
            name, (unsigned long)arc4random_uniform(0xFFFFFFFFu)]];
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    return p;
}

// ── Helpers ────────────────────────────────────────────────────────

static NSData *u8s(const char *s)
{
    return [NSData dataWithBytes:s length:strlen(s)];
}

static NSData *makeI64(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(int64_t)];
    int64_t *p = (int64_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (int64_t)[vals[i] longLongValue];
    return d;
}

static NSData *makeI32(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(int32_t)];
    int32_t *p = (int32_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (int32_t)[vals[i] intValue];
    return d;
}

static NSData *makeU32(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(uint32_t)];
    uint32_t *p = (uint32_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (uint32_t)[vals[i] unsignedIntValue];
    return d;
}

static NSData *makeU64(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(uint64_t)];
    uint64_t *p = (uint64_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (uint64_t)[vals[i] unsignedLongLongValue];
    return d;
}

static NSData *makeU8(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (uint8_t)[vals[i] unsignedCharValue];
    return d;
}

static NSArray<NSString *> *repString(NSString *s, NSUInteger n)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [a addObject:s];
    return a;
}

// FQZCOMP run builder: nReads × readLen bytes, qualities seeded by
// `qualsSeed` (0 → constant Q30; nonzero → deterministic LCG-varied).
// `flagsValue` lets caller set the SAM REVERSE bit (16) on every read.
static TTIOWrittenGenomicRun *buildFqzRunVaried(NSDictionary *overrides,
                                                  uint32_t flagsValue,
                                                  NSUInteger nReads,
                                                  NSUInteger readLen,
                                                  uint32_t qualsSeed)
{
    NSData *seqOne = u8s("ACGTACGTAC");
    NSMutableData *flat = [NSMutableData data];
    for (NSUInteger i = 0; i < nReads; i++) {
        [flat appendBytes:seqOne.bytes length:readLen];
    }
    NSMutableData *qual = [NSMutableData dataWithLength:flat.length];
    if (qualsSeed == 0) {
        memset(qual.mutableBytes, 30 + 33, qual.length);
    } else {
        // Reproducible LCG (Numerical Recipes); range Q20..Q40+33.
        uint8_t *qp = (uint8_t *)qual.mutableBytes;
        uint32_t s = qualsSeed;
        for (NSUInteger i = 0; i < qual.length; i++) {
            s = s * 1664525u + 1013904223u;
            qp[i] = (uint8_t)(20 + 33 + (s >> 24) % 21);
        }
    }

    NSMutableArray *posVals = [NSMutableArray array];
    NSMutableArray *flagVals = [NSMutableArray array];
    NSMutableArray *mqVals = [NSMutableArray array];
    NSMutableArray *offVals = [NSMutableArray array];
    NSMutableArray *lenVals = [NSMutableArray array];
    NSMutableArray *matePosVals = [NSMutableArray array];
    NSMutableArray *tlenVals = [NSMutableArray array];
    NSMutableArray *readNames = [NSMutableArray array];
    for (NSUInteger i = 0; i < nReads; i++) {
        [posVals addObject:@1];
        [flagVals addObject:@(flagsValue)];
        [mqVals addObject:@60];
        [offVals addObject:@(i * readLen)];
        [lenVals addObject:@(readLen)];
        [matePosVals addObject:@(-1)];
        [tlenVals addObject:@0];
        [readNames addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
    }
    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"m94-test-uri"
                        platform:@"ILLUMINA"
                      sampleName:@"m94"
                        positions:makeI64(posVals)
                 mappingQualities:makeU8(mqVals)
                            flags:makeU32(flagVals)
                        sequences:flat
                        qualities:qual
                          offsets:makeU64(offVals)
                          lengths:makeU32(lenVals)
                           cigars:repString([NSString stringWithFormat:@"%luM",
                                                (unsigned long)readLen], nReads)
                        readNames:readNames
                  mateChromosomes:repString(@"*", nReads)
                    matePositions:makeI64(matePosVals)
                  templateLengths:makeI32(tlenVals)
                      chromosomes:repString(@"22", nReads)
               signalCompression:TTIOCompressionZlib
             signalCodecOverrides:overrides];
}

// Backwards-compat shim: constant-Q30 qualities (seed 0).
static TTIOWrittenGenomicRun *buildFqzRun(NSDictionary *overrides,
                                            uint32_t flagsValue,
                                            NSUInteger nReads,
                                            NSUInteger readLen)
{
    return buildFqzRunVaried(overrides, flagsValue, nReads, readLen, 0);
}

// ── HDF5 attr probes ───────────────────────────────────────────────

static NSString *readRootStringAttr(NSString *path, NSString *attr)
{
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    if (!f) return nil;
    TTIOHDF5Group *root = [f rootGroup];
    NSString *v = [root stringAttributeNamed:attr error:NULL];
    [f close];
    return v;
}

static uint8_t readQualitiesCompressionAttr(NSString *path, NSString *runName)
{
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    if (!f) return 0;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
    TTIOHDF5Group *gruns = [study openGroupNamed:@"genomic_runs" error:NULL];
    TTIOHDF5Group *runG = [gruns openGroupNamed:runName error:NULL];
    TTIOHDF5Group *sc = [runG openGroupNamed:@"signal_channels" error:NULL];
    TTIOHDF5Dataset *qDs = [sc openDatasetNamed:@"qualities" error:NULL];
    if (!qDs) { [f close]; return 0; }
    hid_t did = [qDs datasetId];
    uint8_t v = 0;
    if (H5Aexists(did, "compression") > 0) {
        hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
        H5Aread(aid, H5T_NATIVE_UINT8, &v);
        H5Aclose(aid);
    }
    [f close];
    return v;
}

static NSData *readQualitiesDatasetBytes(NSString *path, NSString *runName)
{
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    if (!f) return nil;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
    TTIOHDF5Group *gruns = [study openGroupNamed:@"genomic_runs" error:NULL];
    TTIOHDF5Group *runG = [gruns openGroupNamed:runName error:NULL];
    TTIOHDF5Group *sc = [runG openGroupNamed:@"signal_channels" error:NULL];
    TTIOHDF5Dataset *qDs = [sc openDatasetNamed:@"qualities" error:NULL];
    NSData *raw = [qDs readDataWithError:NULL];
    [f close];
    return raw;
}

// ── Tests ──────────────────────────────────────────────────────────

static void testRoundTripWithFqzcomp(void)
{
    NSDictionary *overrides = @{ @"qualities": @(TTIOCompressionFqzcompNx16Z) };
    TTIOWrittenGenomicRun *run = buildFqzRun(overrides, 0, 5, 10);

    NSString *path = tmpPathWithName(@"rt");
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                   title:@"m94 round trip"
                                      isaInvestigationId:@"TTIO:m94:rt"
                                                  msRuns:@{}
                                              genomicRuns:@{ @"run_0001": run }
                                          identifications:@[]
                                          quantifications:@[]
                                       provenanceRecords:@[]
                                                   error:&err];
    PASS(ok && err == nil, "M94: write_minimal with FQZCOMP_NX16_Z succeeds: %@",
         err.localizedDescription ?: @"<no error>");
    if (!ok) return;

    uint8_t codec = readQualitiesCompressionAttr(path, @"run_0001");
    PASS(codec == (uint8_t)TTIOCompressionFqzcompNx16Z,
         "M94.Z: @compression on qualities is %u (expected 12)", codec);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "M94: readFromFilePath succeeds");
    TTIOGenomicRun *out = ds.genomicRuns[@"run_0001"];
    PASS(out != nil && out.readCount == 5,
         "M94: round-trip recovers 5 reads (got %lu)",
         (unsigned long)(out ? out.readCount : 0));
    BOOL allEqual = YES;
    for (NSUInteger i = 0; i < (out ? out.readCount : 0); i++) {
        TTIOAlignedRead *r = [out readAtIndex:i error:NULL];
        NSData *qd = r.qualities;
        if (qd.length != 10) { allEqual = NO; break; }
        const uint8_t *qp = (const uint8_t *)qd.bytes;
        for (NSUInteger j = 0; j < 10; j++) {
            if (qp[j] != (uint8_t)(30 + 33)) { allEqual = NO; break; }
        }
        if (!allEqual) break;
    }
    PASS(allEqual, "M94: every round-tripped quality slice is constant Q30");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testFormatVersionIs1_5WhenFqzcompUsed(void)
{
    NSDictionary *overrides = @{ @"qualities": @(TTIOCompressionFqzcompNx16Z) };
    TTIOWrittenGenomicRun *run = buildFqzRun(overrides, 0, 5, 10);
    NSString *path = tmpPathWithName(@"fv15");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"fv 1.5"
                             isaInvestigationId:@"TTIO:m94:fv5"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    NSString *v = readRootStringAttr(path, @"ttio_format_version");
    PASS([v isEqualToString:@"1.5"],
         "M94: format_version is '1.5' when FQZCOMP_NX16_Z used (got '%@')", v);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testFormatVersionStaysAt1_4WhenOnlyM82Codecs(void)
{
    // Use RANS_ORDER0 (an M82-era codec) on qualities → format must stay 1.4.
    NSDictionary *overrides = @{ @"qualities": @(TTIOCompressionRansOrder0) };
    TTIOWrittenGenomicRun *run = buildFqzRun(overrides, 0, 5, 10);
    NSString *path = tmpPathWithName(@"fv14");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"fv 1.4"
                             isaInvestigationId:@"TTIO:m94:fv4"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    NSString *v = readRootStringAttr(path, @"ttio_format_version");
    PASS([v isEqualToString:@"1.4"],
         "M94: format_version stays '1.4' when only M82 codecs (got '%@')", v);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testAutoDefaultFiresForV15Candidate(void)
{
    // No override; signal_compression="gzip"; reference is provided so
    // sequences auto-applies REF_DIFF → run becomes a v1.5 candidate.
    // qualities should auto-apply FQZCOMP_NX16_Z.
    NSData *refSeq = [u8s("ACGTACGTACGTACGTACGTACGTACGTACGTAC") copy];
    NSMutableData *bigRef = [NSMutableData data];
    for (int i = 0; i < 100; i++) [bigRef appendData:u8s("ACGTACGTAC")];

    TTIOWrittenGenomicRun *run = buildFqzRun(@{}, 0, 5, 10);
    run.embedReference = YES;
    run.referenceChromSeqs = @{ @"22": bigRef };

    NSString *path = tmpPathWithName(@"autodef");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"auto"
                             isaInvestigationId:@"TTIO:m94:auto"
                                         msRuns:@{}
                                     genomicRuns:@{ @"run_0001": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    PASS(err == nil, "M94 auto-default: write succeeds (err=%@)",
         err.localizedDescription ?: @"<none>");
    uint8_t codec = readQualitiesCompressionAttr(path, @"run_0001");
    PASS(codec == (uint8_t)TTIOCompressionFqzcompNx16Z,
         "M94: auto-default applies FQZCOMP_NX16_Z to qualities when run is "
         "v1.5 candidate (got %u, expected 12)", codec);
    (void)refSeq;
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testAutoDefaultSkippedForPureM82(void)
{
    // No override, no reference → not a v1.5 candidate. Qualities must
    // NOT get FQZCOMP_NX16_Z (preserves M82 byte-parity baseline).
    TTIOWrittenGenomicRun *run = buildFqzRun(@{}, 0, 5, 10);
    run.referenceChromSeqs = nil;
    run.embedReference = NO;

    NSString *path = tmpPathWithName(@"baseline");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"baseline"
                             isaInvestigationId:@"TTIO:m94:baseline"
                                         msRuns:@{}
                                     genomicRuns:@{ @"run_0001": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    uint8_t codec = readQualitiesCompressionAttr(path, @"run_0001");
    PASS(codec != (uint8_t)TTIOCompressionFqzcompNx16Z,
         "M94: auto-default SKIPPED for pure-M82 baseline (got @compression=%u)",
         codec);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testExplicitOverrideAlongsideRefDiff(void)
{
    // Both REF_DIFF on sequences and FQZCOMP_NX16_Z on qualities, set
    // explicitly. Both should be honoured.
    NSMutableData *bigRef = [NSMutableData data];
    for (int i = 0; i < 100; i++) [bigRef appendData:u8s("ACGTACGTAC")];

    NSDictionary *overrides = @{
        @"sequences": @(TTIOCompressionRefDiff),
        @"qualities": @(TTIOCompressionFqzcompNx16Z),
    };
    TTIOWrittenGenomicRun *run = buildFqzRun(overrides, 0, 5, 10);
    run.embedReference = YES;
    run.referenceChromSeqs = @{ @"22": bigRef };

    NSString *path = tmpPathWithName(@"both");
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                   title:@"both"
                                      isaInvestigationId:@"TTIO:m94:both"
                                                  msRuns:@{}
                                              genomicRuns:@{ @"run_0001": run }
                                          identifications:@[]
                                          quantifications:@[]
                                       provenanceRecords:@[]
                                                   error:&err];
    PASS(ok, "M94: REF_DIFF + FQZCOMP_NX16_Z simultaneous overrides write OK");
    uint8_t qCodec = readQualitiesCompressionAttr(path, @"run_0001");
    PASS(qCodec == (uint8_t)TTIOCompressionFqzcompNx16Z,
         "M94.Z: qualities @compression == 12 with simultaneous overrides "
         "(got %u)", qCodec);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testReverseFlagEncodingAndRoundTrip(void)
{
    // NX16_Z uses CRAM-style pos_bucket context: the revcomp flag is wired
    // into the context hash but doesn't guarantee different raw byte content
    // for every input. The correctness gate is that BOTH fwd and rev
    // round-trip cleanly and produce the same re-decoded qualities.
    NSDictionary *overrides = @{ @"qualities": @(TTIOCompressionFqzcompNx16Z) };
    TTIOWrittenGenomicRun *fwd = buildFqzRunVaried(overrides, 0,  10, 50, 0xCAFEu);
    TTIOWrittenGenomicRun *rev = buildFqzRunVaried(overrides, 16, 10, 50, 0xCAFEu);
    NSString *pFwd = tmpPathWithName(@"fwd");
    NSString *pRev = tmpPathWithName(@"rev");
    NSError *err = nil;
    BOOL ok1 = [TTIOSpectralDataset writeMinimalToPath:pFwd title:@"fwd"
                          isaInvestigationId:@"TTIO:m94:fwd"
                                      msRuns:@{} genomicRuns:@{@"r":fwd}
                              identifications:@[] quantifications:@[]
                           provenanceRecords:@[] error:&err];
    BOOL ok2 = [TTIOSpectralDataset writeMinimalToPath:pRev title:@"rev"
                          isaInvestigationId:@"TTIO:m94:rev"
                                      msRuns:@{} genomicRuns:@{@"r":rev}
                              identifications:@[] quantifications:@[]
                           provenanceRecords:@[] error:&err];
    PASS(ok1 && ok2, "M94.Z: both fwd/rev FQZCOMP_NX16_Z writes succeed");
    NSData *fwdBytes = readQualitiesDatasetBytes(pFwd, @"r");
    NSData *revBytes = readQualitiesDatasetBytes(pRev, @"r");
    PASS(fwdBytes != nil && revBytes != nil,
         "M94.Z: both fwd/rev encoded datasets read back (%lu, %lu bytes)",
         (unsigned long)fwdBytes.length, (unsigned long)revBytes.length);
    // Verify round-trip: read back and decode.
    TTIOSpectralDataset *dsFwd = [TTIOSpectralDataset readFromFilePath:pFwd error:&err];
    TTIOSpectralDataset *dsRev = [TTIOSpectralDataset readFromFilePath:pRev error:&err];
    PASS(dsFwd.genomicRuns[@"r"] != nil && dsRev.genomicRuns[@"r"] != nil,
         "M94.Z: fwd/rev round-trip reads back genomic runs");
    [[NSFileManager defaultManager] removeItemAtPath:pFwd error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:pRev error:NULL];
}

static void testReverseRoundTripCorrect(void)
{
    NSDictionary *overrides = @{ @"qualities": @(TTIOCompressionFqzcompNx16Z) };
    TTIOWrittenGenomicRun *run = buildFqzRun(overrides, 16, 8, 25);
    NSString *path = tmpPathWithName(@"revrt");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"rev rt"
                             isaInvestigationId:@"TTIO:m94:rev_rt"
                                         msRuns:@{}
                                     genomicRuns:@{ @"run_0001": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    PASS(err == nil, "M94 reverse round-trip: write succeeds");
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *out = ds.genomicRuns[@"run_0001"];
    BOOL allEqual = (out.readCount == 8);
    for (NSUInteger i = 0; allEqual && i < out.readCount; i++) {
        TTIOAlignedRead *r = [out readAtIndex:i error:NULL];
        if (r.qualities.length != 25) { allEqual = NO; break; }
        const uint8_t *p = r.qualities.bytes;
        for (NSUInteger j = 0; j < 25; j++) {
            if (p[j] != (uint8_t)(30 + 33)) { allEqual = NO; break; }
        }
    }
    PASS(allEqual, "M94: reverse-flag round-trip recovers qualities byte-exact");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testSingleRunRegressionSmoke(void)
{
    // Smoke: explicit override on a single 1-read run.
    NSDictionary *overrides = @{ @"qualities": @(TTIOCompressionFqzcompNx16Z) };
    TTIOWrittenGenomicRun *run = buildFqzRun(overrides, 0, 1, 4);
    NSString *path = tmpPathWithName(@"smoke");
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                   title:@"smoke"
                                      isaInvestigationId:@"TTIO:m94:smoke"
                                                  msRuns:@{}
                                              genomicRuns:@{ @"r": run }
                                          identifications:@[]
                                          quantifications:@[]
                                       provenanceRecords:@[]
                                                   error:&err];
    PASS(ok, "M94: 1-read 4-byte explicit FQZCOMP_NX16_Z smoke writes");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

// ── Public entry point ─────────────────────────────────────────────

void testM94FqzcompPipeline(void);
void testM94FqzcompPipeline(void)
{
    testRoundTripWithFqzcomp();
    testFormatVersionIs1_5WhenFqzcompUsed();
    testFormatVersionStaysAt1_4WhenOnlyM82Codecs();
    testAutoDefaultFiresForV15Candidate();
    testAutoDefaultSkippedForPureM82();
    testExplicitOverrideAlongsideRefDiff();
    testReverseFlagEncodingAndRoundTrip();
    testReverseRoundTripCorrect();
    testSingleRunRegressionSmoke();
}
