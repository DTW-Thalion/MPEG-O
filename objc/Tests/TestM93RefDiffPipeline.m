// TestM93RefDiffPipeline.m — v1.2 M93 Phase 2 pipeline integration tests.
//
// Mirrors python/tests/test_m93_ref_diff_pipeline.py. Round-trip via
// +writeMinimalToPath: + readFromFilePath:, format-version gating,
// embedded references, dedup, fallback, RefMissingError.
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

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── tmp dir ────────────────────────────────────────────────────────

static NSString *tmpPathWithName(NSString *name)
{
    NSString *base = NSTemporaryDirectory();
    if (!base.length) base = @"/tmp";
    NSString *p = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ttio_m93_%@_%lu.tio",
            name, (unsigned long)arc4random_uniform(0xFFFFFFFFu)]];
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    return p;
}

// ── Helpers ────────────────────────────────────────────────────────

static NSData *u8(const char *s)
{
    return [NSData dataWithBytes:s length:strlen(s)];
}

static NSData *intArr(NSArray<NSNumber *> *vals, size_t elem)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * elem];
    if (elem == 8) {
        int64_t *p = (int64_t *)d.mutableBytes;
        for (NSUInteger i = 0; i < vals.count; i++) p[i] = (int64_t)[vals[i] longLongValue];
    } else if (elem == 4) {
        // signed int32 by default for tlen, unsigned for flags. Caller
        // chooses which array to feed; we just write the low 32 bits.
        int32_t *p = (int32_t *)d.mutableBytes;
        for (NSUInteger i = 0; i < vals.count; i++) p[i] = (int32_t)[vals[i] intValue];
    } else if (elem == 1) {
        uint8_t *p = (uint8_t *)d.mutableBytes;
        for (NSUInteger i = 0; i < vals.count; i++) p[i] = (uint8_t)[vals[i] unsignedCharValue];
    } else if (elem == 8 + 0xff) {
        // unused
    }
    return d;
}

static NSData *u64Arr(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(uint64_t)];
    uint64_t *p = (uint64_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (uint64_t)[vals[i] unsignedLongLongValue];
    return d;
}

static NSData *u32Arr(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(uint32_t)];
    uint32_t *p = (uint32_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (uint32_t)[vals[i] unsignedIntValue];
    return d;
}

static NSArray<NSString *> *repeatString(NSString *s, NSUInteger n)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [a addObject:s];
    return a;
}

// Build a ref-diff WrittenGenomicRun: 5 reads of "ACGTACGTAC" against
// a 1000bp ref, REF_DIFF override on sequences.
static TTIOWrittenGenomicRun *buildRefDiffRun(NSString *refUri,
                                                NSData *refChromSeq,
                                                BOOL embedReference)
{
    NSUInteger n = 5;
    NSData *seq = u8("ACGTACGTAC");   // 10 bp
    NSMutableData *flat = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) [flat appendData:seq];
    NSMutableData *qual = [NSMutableData dataWithLength:flat.length];
    memset(qual.mutableBytes, 30, qual.length);

    NSMutableArray *posVals = [NSMutableArray array];
    NSMutableArray *flagVals = [NSMutableArray array];
    NSMutableArray *mqVals = [NSMutableArray array];
    NSMutableArray *offVals = [NSMutableArray array];
    NSMutableArray *lenVals = [NSMutableArray array];
    NSMutableArray *matePosVals = [NSMutableArray array];
    NSMutableArray *tlenVals = [NSMutableArray array];
    NSMutableArray *readNames = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [posVals addObject:@1];
        [flagVals addObject:@0];
        [mqVals addObject:@60];
        [offVals addObject:@(i * 10)];
        [lenVals addObject:@10];
        [matePosVals addObject:@(-1)];
        [tlenVals addObject:@0];
        [readNames addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
    }
    NSDictionary *overrides = @{ @"sequences": @(TTIOCompressionRefDiff) };
    TTIOWrittenGenomicRun *r = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:refUri
                        platform:@"ILLUMINA"
                      sampleName:@"test"
                        positions:intArr(posVals, 8)
                 mappingQualities:intArr(mqVals, 1)
                            flags:u32Arr(flagVals)
                        sequences:flat
                        qualities:qual
                          offsets:u64Arr(offVals)
                          lengths:u32Arr(lenVals)
                           cigars:repeatString(@"10M", n)
                        readNames:readNames
                  mateChromosomes:repeatString(@"*", n)
                    matePositions:intArr(matePosVals, 8)
                  templateLengths:intArr(tlenVals, 4)
                      chromosomes:repeatString(@"22", n)
               signalCompression:TTIOCompressionZlib
             signalCodecOverrides:overrides];
    r.embedReference = embedReference;
    if (embedReference && refChromSeq) {
        r.referenceChromSeqs = @{ @"22": refChromSeq };
    } else {
        r.referenceChromSeqs = nil;
    }
    // v1.8 #11: these M93 tests assert the v1 REF_DIFF flat-dataset layout
    // (@compression=9). Disable the v2 group path so layout assertions hold.
    r.optDisableRefDiffV2 = YES;
    return r;
}

// M82-only run (no codec override) — used to verify format-version stays 1.4.
static TTIOWrittenGenomicRun *buildM82OnlyRun(void)
{
    NSUInteger n = 3;
    NSData *seq = u8("ACGTACGT");
    NSMutableData *flat = [NSMutableData data];
    for (NSUInteger i = 0; i < n; i++) [flat appendData:seq];
    NSMutableData *qual = [NSMutableData dataWithLength:flat.length];
    memset(qual.mutableBytes, 25, qual.length);

    NSMutableArray *posVals = [NSMutableArray array];
    NSMutableArray *flagVals = [NSMutableArray array];
    NSMutableArray *mqVals = [NSMutableArray array];
    NSMutableArray *offVals = [NSMutableArray array];
    NSMutableArray *lenVals = [NSMutableArray array];
    NSMutableArray *matePosVals = [NSMutableArray array];
    NSMutableArray *tlenVals = [NSMutableArray array];
    NSMutableArray *readNames = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [posVals addObject:@(i + 1)];
        [flagVals addObject:@0];
        [mqVals addObject:@60];
        [offVals addObject:@(i * 8)];
        [lenVals addObject:@8];
        [matePosVals addObject:@(-1)];
        [tlenVals addObject:@0];
        [readNames addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
    }
    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"m82-only-uri"
                        platform:@"ILLUMINA"
                      sampleName:@"m82"
                        positions:intArr(posVals, 8)
                 mappingQualities:intArr(mqVals, 1)
                            flags:u32Arr(flagVals)
                        sequences:flat
                        qualities:qual
                          offsets:u64Arr(offVals)
                          lengths:u32Arr(lenVals)
                           cigars:repeatString(@"8M", n)
                        readNames:readNames
                  mateChromosomes:repeatString(@"*", n)
                    matePositions:intArr(matePosVals, 8)
                  templateLengths:intArr(tlenVals, 4)
                      chromosomes:repeatString(@"22", n)
               signalCompression:TTIOCompressionZlib];
}

static NSData *bigRef(void)
{
    NSData *one = u8("ACGTACGTAC");
    NSMutableData *d = [NSMutableData data];
    for (int i = 0; i < 100; i++) [d appendData:one];
    return d;
}

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

// ── Tests ──────────────────────────────────────────────────────────

static void testRoundTripWithRefDiff(void)
{
    TTIOWrittenGenomicRun *run = buildRefDiffRun(@"test-ref-uri",
                                                  bigRef(), YES);
    NSString *path = tmpPathWithName(@"rt");
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                   title:@"m93 round trip"
                                      isaInvestigationId:@"TTIO:m93:rt"
                                                  msRuns:@{}
                                              genomicRuns:@{ @"run_0001": run }
                                          identifications:@[]
                                          quantifications:@[]
                                       provenanceRecords:@[]
                                                   error:&err];
    PASS(ok && err == nil, "M93: write_minimal with REF_DIFF succeeds: %@",
         err.localizedDescription ?: @"<no error>");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "M93: readFromFilePath succeeds");
    TTIOGenomicRun *out = ds.genomicRuns[@"run_0001"];
    PASS(out != nil && out.readCount == 5,
         "M93: round-trip recovers 5 reads (got %lu)",
         (unsigned long)(out ? out.readCount : 0));
    BOOL allEqual = YES;
    for (NSUInteger i = 0; i < (out ? out.readCount : 0); i++) {
        TTIOAlignedRead *r = [out readAtIndex:i error:NULL];
        if (![r.sequence isEqualToString:@"ACGTACGTAC"]) {
            allEqual = NO;
            fprintf(stderr,
                    "  read %lu sequence='%s' (expected ACGTACGTAC)\n",
                    (unsigned long)i, [r.sequence UTF8String] ?: "<nil>");
            break;
        }
    }
    PASS(allEqual, "M93: every round-tripped read is 'ACGTACGTAC'");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testFormatVersionIs1_5WhenRefDiffUsed(void)
{
    TTIOWrittenGenomicRun *run = buildRefDiffRun(@"x-uri",
                                                  bigRef(), YES);
    NSString *path = tmpPathWithName(@"fv15");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"fv 1.5"
                             isaInvestigationId:@"TTIO:m93:fv5"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    NSString *v = readRootStringAttr(path, @"ttio_format_version");
    PASS([v isEqualToString:@"1.5"],
         "M93: format_version is '1.5' when REF_DIFF used (got '%@')", v);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testFormatVersionStaysAt1_4ForM82Only(void)
{
    TTIOWrittenGenomicRun *run = buildM82OnlyRun();
    NSString *path = tmpPathWithName(@"fv14");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"fv 1.4"
                             isaInvestigationId:@"TTIO:m82:fv4"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];
    NSString *v = readRootStringAttr(path, @"ttio_format_version");
    PASS([v isEqualToString:@"1.4"],
         "M93: format_version stays '1.4' when only M82 codecs (got '%@')", v);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testEmbeddedReferenceAtCanonicalPath(void)
{
    NSData *refSeq = bigRef();
    TTIOWrittenGenomicRun *run = buildRefDiffRun(@"test-ref-uri", refSeq, YES);
    NSString *path = tmpPathWithName(@"embed");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"embed"
                             isaInvestigationId:@"TTIO:m93:e"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
    TTIOHDF5Group *refs = [study openGroupNamed:@"references" error:NULL];
    TTIOHDF5Group *refG = [refs openGroupNamed:@"test-ref-uri" error:NULL];
    PASS(refG != nil, "M93: /study/references/<uri> embedded");
    NSString *md5Hex = [refG stringAttributeNamed:@"md5" error:NULL];
    PASS(md5Hex.length == 32, "M93: embedded ref has 32-hex md5 (got %lu chars)",
         (unsigned long)md5Hex.length);
    TTIOHDF5Group *chromsG = [refG openGroupNamed:@"chromosomes" error:NULL];
    TTIOHDF5Group *chromG = [chromsG openGroupNamed:@"22" error:NULL];
    TTIOHDF5Dataset *dsD = [chromG openDatasetNamed:@"data" error:NULL];
    NSData *bytes = [dsD readDataWithError:NULL];
    PASS([bytes isEqualToData:refSeq],
         "M93: embedded chrom data byte-exact (%lu bytes)",
         (unsigned long)bytes.length);
    [f close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testTwoRunsSharingReferenceDedupe(void)
{
    NSData *refSeq = bigRef();
    TTIOWrittenGenomicRun *a = buildRefDiffRun(@"shared-uri", refSeq, YES);
    TTIOWrittenGenomicRun *b = buildRefDiffRun(@"shared-uri", refSeq, YES);
    NSString *path = tmpPathWithName(@"dedup");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"dedup"
                             isaInvestigationId:@"TTIO:m93:d"
                                         msRuns:@{}
                                     genomicRuns:@{ @"run_a": a, @"run_b": b }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
    TTIOHDF5Group *refs = [study openGroupNamed:@"references" error:NULL];
    NSArray<NSString *> *names = [refs childNames];
    PASS(names.count == 1 && [names[0] isEqualToString:@"shared-uri"],
         "M93: dedup → exactly one /study/references child (got %lu: %@)",
         (unsigned long)names.count, names);
    [f close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testTwoRunsSameURIDifferentMD5Raises(void)
{
    NSMutableData *refA = [NSMutableData data];
    for (int i = 0; i < 100; i++) [refA appendData:u8("ACGTACGTAC")];
    NSMutableData *refB = [NSMutableData data];
    for (int i = 0; i < 100; i++) [refB appendData:u8("TTTTTTTTTT")];
    TTIOWrittenGenomicRun *a = buildRefDiffRun(@"conflict-uri", refA, YES);
    TTIOWrittenGenomicRun *b = buildRefDiffRun(@"conflict-uri", refB, YES);
    NSString *path = tmpPathWithName(@"conflict");
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                   title:@"conflict"
                                      isaInvestigationId:@"TTIO:m93:c"
                                                  msRuns:@{}
                                              genomicRuns:@{ @"a": a, @"b": b }
                                          identifications:@[]
                                          quantifications:@[]
                                       provenanceRecords:@[]
                                                   error:&err];
    PASS(!ok && err != nil &&
         [err.localizedDescription rangeOfString:@"MD5"].location != NSNotFound,
         "M93: same URI with different MD5 → NSError mentioning MD5 "
         "(got ok=%d, msg='%@')", (int)ok, err.localizedDescription);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testRefDiffFallsBackToBasePackWhenNoRef(void)
{
    TTIOWrittenGenomicRun *run = buildRefDiffRun(@"x-uri", nil, NO);
    run.referenceChromSeqs = nil;
    NSString *path = tmpPathWithName(@"fallback");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"fallback"
                             isaInvestigationId:@"TTIO:m93:f"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
    TTIOHDF5Group *gruns = [study openGroupNamed:@"genomic_runs" error:NULL];
    TTIOHDF5Group *runG = [gruns openGroupNamed:@"r" error:NULL];
    TTIOHDF5Group *sc = [runG openGroupNamed:@"signal_channels" error:NULL];
    TTIOHDF5Dataset *seqDs = [sc openDatasetNamed:@"sequences" error:NULL];

    // Read @compression attribute (uint8). H5A direct path.
    hid_t did = [seqDs datasetId];
    uint8_t codec = 0;
    if (H5Aexists(did, "compression") > 0) {
        hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
        H5Aread(aid, H5T_NATIVE_UINT8, &codec);
        H5Aclose(aid);
    }
    PASS(codec == (uint8_t)TTIOCompressionBasePack,
         "M93: fallback to BASE_PACK when no ref (got @compression=%u, expected 6)",
         (unsigned)codec);
    [f close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void testRefMissingAtReadRaises(void)
{
    TTIOWrittenGenomicRun *run = buildRefDiffRun(@"test-ref-uri",
                                                  bigRef(), YES);
    NSString *path = tmpPathWithName(@"missing");
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                          title:@"missing"
                             isaInvestigationId:@"TTIO:m93:m"
                                         msRuns:@{}
                                     genomicRuns:@{ @"r": run }
                                 identifications:@[]
                                 quantifications:@[]
                              provenanceRecords:@[]
                                          error:&err];

    // Surgically delete the embedded reference group.
    {
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:&err];
        if (f) {
            TTIOHDF5Group *root = [f rootGroup];
            TTIOHDF5Group *study = [root openGroupNamed:@"study" error:NULL];
            TTIOHDF5Group *refs = [study openGroupNamed:@"references" error:NULL];
            (void)[refs deleteChildNamed:@"test-ref-uri" error:NULL];
            [f close];
        }
    }

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *out = ds.genomicRuns[@"r"];
    NSError *readErr = nil;
    TTIOAlignedRead *r0 = [out readAtIndex:0 error:&readErr];
    PASS(r0 == nil || (r0 != nil && r0.sequence == nil) || readErr != nil,
         "M93: read with missing reference returns nil or NSError "
         "(got read=%@ err=%@)",
         r0 ? @"non-nil" : @"nil",
         readErr.localizedDescription ?: @"<no error>");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

// ── Public entry point ─────────────────────────────────────────────

void testM93RefDiffPipeline(void);
void testM93RefDiffPipeline(void)
{
    testRoundTripWithRefDiff();
    testFormatVersionIs1_5WhenRefDiffUsed();
    testFormatVersionStaysAt1_4ForM82Only();
    testEmbeddedReferenceAtCanonicalPath();
    testTwoRunsSharingReferenceDedupe();
    testTwoRunsSameURIDifferentMD5Raises();
    testRefDiffFallsBackToBasePackWhenNoRef();
    testRefMissingAtReadRaises();
}
