/*
 * TestPhase12RunProtocol — Phase 1 + Phase 2 abstraction polish
 *  parity with the Python reference impl
 *  (python/tests/test_run_protocol.py).
 *
 * Phase 1:
 *   - TTIORun protocol declared; both TTIOAcquisitionRun and
 *     TTIOGenomicRun conform.
 *   - TTIOGenomicRun -provenanceChain reads <run>/provenance/steps,
 *     closing the M91 read-side cross-modality query gap.
 *   - TTIOSpectralDataset gains -runsForSample: and -runsOfModality:
 *     accessors plus -allRunsUnified (Phase 1 alias for Phase 2's
 *     canonical -runs).
 *
 * Phase 2:
 *   - TTIOSpectralDataset -runs is the canonical unified mapping.
 *   - +writeMinimalToPath:...mixedRuns:... accepts a single dict
 *     containing both TTIOWrittenRun and TTIOWrittenGenomicRun
 *     values, dispatching per-value. Name collision between the
 *     mixedRuns and genomicRuns kwargs raises NSError.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#include <string.h>

#import "Protocols/TTIORun.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *kSampleURI = @"sample://NA12878";

static NSString *tmpPathSuffix(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_phase12_%d_%@.tio",
            (int)getpid(), suffix];
}

// ── Helpers ──────────────────────────────────────────────────────────

static NSData *_f64Buf(const double *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(double)];
}
static NSData *_i32Buf(const int32_t *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(int32_t)];
}
static NSData *_i64Buf(const int64_t *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(int64_t)];
}
static NSData *_u32Buf(const uint32_t *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(uint32_t)];
}
static NSData *_u64Buf(const uint64_t *v, NSUInteger n)
{
    return [NSData dataWithBytes:v length:n * sizeof(uint64_t)];
}

static TTIOWrittenRun *makeMSRunWithProv(BOOL withProv)
{
    NSUInteger n = 3, peaks = 4, total = n * peaks;
    double mz[12];
    double intensity[12];
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + (double)i;
        intensity[i] = (double)(i + 1) * 1000.0;
    }
    int64_t  offsets[3]  = {0, 4, 8};
    uint32_t lengths[3]  = {4, 4, 4};
    double   rts[3]      = {0.0, 2.0, 4.0};
    int32_t  msLevels[3] = {1, 1, 1};
    int32_t  pols[3]     = {(int32_t)TTIOPolarityPositive,
                             (int32_t)TTIOPolarityPositive,
                             (int32_t)TTIOPolarityPositive};
    double   pmzs[3]     = {0.0, 0.0, 0.0};
    int32_t  pcs[3]      = {0, 0, 0};
    double   bpis[3]     = {4000.0, 8000.0, 12000.0};

    TTIOWrittenRun *r = [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz":        _f64Buf(mz, total),
                                    @"intensity": _f64Buf(intensity, total)}
                          offsets:[NSData dataWithBytes:offsets length:sizeof(offsets)]
                          lengths:_u32Buf(lengths, n)
                   retentionTimes:_f64Buf(rts, n)
                         msLevels:_i32Buf(msLevels, n)
                       polarities:_i32Buf(pols, n)
                     precursorMzs:_f64Buf(pmzs, n)
                 precursorCharges:_i32Buf(pcs, n)
              basePeakIntensities:_f64Buf(bpis, n)];
    if (withProv) {
        TTIOProvenanceRecord *rec = [[TTIOProvenanceRecord alloc]
            initWithInputRefs:@[kSampleURI]
                     software:@"ms-pipeline"
                   parameters:@{}
                   outputRefs:@[@"ms://run_0001"]
                timestampUnix:0];
        r.provenanceRecords = @[rec];
    }
    return r;
}

static TTIOWrittenGenomicRun *makeGenomicRunWithProv(BOOL withProv)
{
    NSUInteger nReads = 4;
    NSUInteger L = 8;

    int64_t  positions[4] = {100, 200, 300, 400};
    uint8_t  mapqs[4]     = {60, 60, 60, 60};
    uint32_t flags[4]     = {0x0003, 0x0003, 0x0003, 0x0003};
    uint64_t offsets[4]   = {0, 8, 16, 24};
    uint32_t lengths[4]   = {(uint32_t)L, (uint32_t)L, (uint32_t)L, (uint32_t)L};
    int64_t  matePos[4]   = {-1, -1, -1, -1};
    int32_t  tlens[4]     = {0, 0, 0, 0};

    NSMutableData *seq = [NSMutableData dataWithLength:nReads * L];
    memcpy(seq.mutableBytes, "ACGTACGT", L);
    memcpy((char *)seq.mutableBytes + L,     "ACGTACGT", L);
    memcpy((char *)seq.mutableBytes + 2 * L, "ACGTACGT", L);
    memcpy((char *)seq.mutableBytes + 3 * L, "ACGTACGT", L);
    NSMutableData *quals = [NSMutableData dataWithLength:nReads * L];
    memset(quals.mutableBytes, 30, nReads * L);

    NSArray<NSString *> *cigars = @[@"8M", @"8M", @"8M", @"8M"];
    NSArray<NSString *> *names  = @[@"r0", @"r1", @"r2", @"r3"];
    NSArray<NSString *> *mateChroms = @[@"", @"", @"", @""];
    NSArray<NSString *> *chroms = @[@"chr1", @"chr1", @"chr2", @"chr2"];

    TTIOWrittenGenomicRun *g = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:(TTIOAcquisitionMode)7
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"NA12878"
                      positions:_i64Buf(positions, nReads)
               mappingQualities:[NSData dataWithBytes:mapqs length:nReads]
                          flags:_u32Buf(flags, nReads)
                      sequences:seq
                      qualities:quals
                        offsets:_u64Buf(offsets, nReads)
                        lengths:_u32Buf(lengths, nReads)
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:_i64Buf(matePos, nReads)
                templateLengths:_i32Buf(tlens, nReads)
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];

    if (withProv) {
        TTIOProvenanceRecord *rec = [[TTIOProvenanceRecord alloc]
            initWithInputRefs:@[kSampleURI]
                     software:@"genomics-pipeline"
                   parameters:@{}
                   outputRefs:@[@"genomics://wgs_0001"]
                timestampUnix:0];
        g.provenanceRecords = @[rec];
    }
    return g;
}

static NSString *writeMixedFixture(void)
{
    NSString *path = tmpPathSuffix(@"mixed");
    unlink([path fileSystemRepresentation]);

    TTIOWrittenRun *ms = makeMSRunWithProv(YES);
    TTIOWrittenGenomicRun *g = makeGenomicRunWithProv(YES);

    // Both runs now carry a per-run provenance record whose inputRefs
    // contain ``kSampleURI``; the MS side gained the field as part of
    // closing the deferred ObjC parity gap with Python's
    // ``WrittenRun.provenance_records`` and Java's
    // ``WrittenRun.provenanceRecords``. ``runsForSample`` is therefore
    // expected to find BOTH runs cross-modality.
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"phase1 fixture"
                                    isaInvestigationId:@"ISA-PHASE1"
                                                msRuns:@{@"ms_0001": ms}
                                            genomicRuns:@{@"genomic_0001": g}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "Phase1: writeMinimal succeeds for mixed MS+genomic fixture");
    return path;
}

// ── Tests ────────────────────────────────────────────────────────────

static void testRunProtocolConformance(void)
{
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];
    PASS(ds != nil, "Phase1: dataset reopens");

    TTIOAcquisitionRun *ms = ds.msRuns[@"ms_0001"];
    TTIOGenomicRun     *g  = ds.genomicRuns[@"genomic_0001"];

    PASS([ms conformsToProtocol:@protocol(TTIORun)],
         "Phase1: TTIOAcquisitionRun conforms to TTIORun protocol");
    PASS([g conformsToProtocol:@protocol(TTIORun)],
         "Phase1: TTIOGenomicRun conforms to TTIORun protocol");

    PASS([ms.name isEqualToString:@"ms_0001"],
         "Phase1: AcquisitionRun.name populated from on-disk run name");
    PASS([g.name isEqualToString:@"genomic_0001"],
         "Phase1: GenomicRun.name populated from on-disk run name");

    PASS([ms count] > 0,
         "Phase1: AcquisitionRun -count > 0 (Indexable surface)");
    PASS([g count] > 0,
         "Phase1: GenomicRun -count > 0 (Indexable surface)");

    id<TTIORun> msr = (id<TTIORun>)ms;
    id<TTIORun> grr = (id<TTIORun>)g;
    PASS([(NSObject *)msr respondsToSelector:@selector(provenanceChain)],
         "Phase1: AcquisitionRun responds to -provenanceChain via TTIORun");
    PASS([(NSObject *)grr respondsToSelector:@selector(provenanceChain)],
         "Phase1: GenomicRun responds to -provenanceChain via TTIORun");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testProtocolMethodsCallableUniformly(void)
{
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];

    NSArray<id<TTIORun>> *runs = @[
        (id<TTIORun>)ds.msRuns[@"ms_0001"],
        (id<TTIORun>)ds.genomicRuns[@"genomic_0001"],
    ];
    BOOL allOk = YES;
    for (id<TTIORun> run in runs) {
        if (![(NSObject *)run conformsToProtocol:@protocol(TTIORun)]) allOk = NO;
        if (!run.name || run.name.length == 0) allOk = NO;
        if ([run count] == 0) allOk = NO;
        NSArray *chain = [run provenanceChain];
        if (![chain isKindOfClass:[NSArray class]]) allOk = NO;
    }
    PASS(allOk,
         "Phase1: TTIORun surface usable uniformly across modalities");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testMSProvenanceChainPopulated(void)
{
    // Closes the ObjC-side parity gap with Python's
    // ``WrittenRun.provenance_records`` / Java's
    // ``WrittenRun.provenanceRecords``: writing an MS WrittenRun whose
    // provenanceRecords carry one record must round-trip through
    // ``writeMinimalToPath:`` and reappear on the reopened
    // ``TTIOAcquisitionRun.provenanceChain``.
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];

    TTIOAcquisitionRun *ms = ds.msRuns[@"ms_0001"];
    NSArray<TTIOProvenanceRecord *> *chain = [ms provenanceChain];
    PASS(chain.count == 1,
         "Item2: AcquisitionRun -provenanceChain returns 1 record from "
         "MS WrittenRun.provenanceRecords");
    if (chain.count == 1) {
        TTIOProvenanceRecord *r = chain[0];
        PASS([r.inputRefs containsObject:kSampleURI],
             "Item2: MS chain[0].inputRefs contains sample URI");
        PASS([r.software isEqualToString:@"ms-pipeline"],
             "Item2: MS chain[0].software round-trips");
    }

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testGenomicProvenanceChainPopulated(void)
{
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];

    TTIOGenomicRun *g = ds.genomicRuns[@"genomic_0001"];
    NSArray<TTIOProvenanceRecord *> *chain = [g provenanceChain];
    PASS(chain.count == 1,
         "Phase1: GenomicRun -provenanceChain returns 1 record from fixture");
    if (chain.count == 1) {
        TTIOProvenanceRecord *r = chain[0];
        PASS([r.inputRefs containsObject:kSampleURI],
             "Phase1: chain[0].inputRefs contains sample URI");
        PASS([r.software isEqualToString:@"genomics-pipeline"],
             "Phase1: chain[0].software round-trips");
    }

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testGenomicProvenanceChainEmpty(void)
{
    NSString *path = tmpPathSuffix(@"noprov");
    unlink([path fileSystemRepresentation]);

    TTIOWrittenGenomicRun *g = makeGenomicRunWithProv(NO);
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"x"
                                    isaInvestigationId:@"x"
                                                msRuns:@{}
                                            genomicRuns:@{@"genomic_0001": g}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "Phase1: noprov fixture writes");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSArray *chain = [gr provenanceChain];
    PASS(chain != nil && chain.count == 0,
         "Phase1: empty per-run provenance returns empty array");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testRunsCanonicalAccessor(void)
{
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];

    NSDictionary<NSString *, id<TTIORun>> *unified = [ds runs];
    PASS(unified[@"ms_0001"] != nil,
         "Phase2: -runs includes MS run");
    PASS(unified[@"genomic_0001"] != nil,
         "Phase2: -runs includes genomic run");

    BOOL allConform = YES;
    for (NSString *k in unified) {
        if (![(NSObject *)unified[k] conformsToProtocol:@protocol(TTIORun)]) {
            allConform = NO;
            break;
        }
    }
    PASS(allConform,
         "Phase2: every value in -runs conforms to TTIORun");

    NSDictionary *alias = [ds allRunsUnified];
    PASS([alias isEqualToDictionary:unified],
         "Phase2: -allRunsUnified is an alias for -runs");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testRunsForSampleCrossModality(void)
{
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];

    NSDictionary *matching = [ds runsForSample:kSampleURI];
    // Both runs now carry the sample URI in their per-run provenance
    // chains; the accessor walks both modalities uniformly through
    // the TTIORun protocol and surfaces both matches.
    PASS(matching[@"genomic_0001"] != nil,
         "Phase1: runsForSample finds genomic run via TTIORun protocol");
    PASS(matching[@"ms_0001"] != nil,
         "Phase1: runsForSample finds MS run via TTIORun protocol");
    PASS([(NSObject *)matching[@"genomic_0001"]
              conformsToProtocol:@protocol(TTIORun)],
         "Phase1: runsForSample genomic value conforms to TTIORun");
    PASS([(NSObject *)matching[@"ms_0001"]
              conformsToProtocol:@protocol(TTIORun)],
         "Phase1: runsForSample MS value conforms to TTIORun");

    NSDictionary *empty = [ds runsForSample:@"sample://UNKNOWN"];
    PASS(empty.count == 0,
         "Phase1: runsForSample returns empty dict for unknown URI");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testRunsOfModality(void)
{
    NSString *path = writeMixedFixture();
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];

    NSDictionary *msOnly = [ds runsOfModality:[TTIOAcquisitionRun class]];
    NSDictionary *gOnly  = [ds runsOfModality:[TTIOGenomicRun class]];
    PASS(msOnly[@"ms_0001"] != nil && msOnly.count == 1,
         "Phase1: runsOfModality(AcquisitionRun) returns MS run only");
    PASS(gOnly[@"genomic_0001"] != nil && gOnly.count == 1,
         "Phase1: runsOfModality(GenomicRun) returns genomic run only");

    BOOL allRun = YES;
    for (NSString *k in msOnly) {
        if (![(NSObject *)msOnly[k] conformsToProtocol:@protocol(TTIORun)]) {
            allRun = NO;
            break;
        }
    }
    for (NSString *k in gOnly) {
        if (![(NSObject *)gOnly[k] conformsToProtocol:@protocol(TTIORun)]) {
            allRun = NO;
            break;
        }
    }
    PASS(allRun,
         "Phase1: runsOfModality values conform to TTIORun");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testMixedRunsWriteAPI(void)
{
    NSString *path = tmpPathSuffix(@"mixedwrite");
    unlink([path fileSystemRepresentation]);

    TTIOWrittenRun *ms = makeMSRunWithProv(NO);
    TTIOWrittenGenomicRun *g = makeGenomicRunWithProv(NO);

    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"Phase2 mixed write"
                                    isaInvestigationId:@"ISA-PHASE2"
                                              mixedRuns:@{
                                                  @"ms_0001":      ms,
                                                  @"genomic_0001": g,
                                              }
                                            genomicRuns:nil
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok,
         "Phase2: mixedRuns write splits MS+genomic dispatch by class");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:NULL];
    PASS(ds.msRuns[@"ms_0001"] != nil,
         "Phase2: ms_0001 round-trips into msRuns");
    PASS(ds.genomicRuns[@"genomic_0001"] != nil,
         "Phase2: genomic_0001 round-trips into genomicRuns");
    NSDictionary *unified = [ds runs];
    PASS(unified[@"ms_0001"] != nil && unified[@"genomic_0001"] != nil,
         "Phase2: -runs sees both runs from a single mixedRuns write");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testMixedRunsNameCollisionRaises(void)
{
    NSString *path = tmpPathSuffix(@"collision");
    unlink([path fileSystemRepresentation]);

    TTIOWrittenGenomicRun *g = makeGenomicRunWithProv(NO);
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"x"
                                    isaInvestigationId:@"x"
                                              mixedRuns:@{@"x": g}
                                            genomicRuns:@{@"x": g}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(!ok && err != nil,
         "Phase2: name collision between mixedRuns and genomicRuns "
         "returns NO with NSError");
    if (err) {
        NSString *msg = err.userInfo[NSLocalizedDescriptionKey];
        PASS([msg rangeOfString:@"appears in both"].location != NSNotFound,
             "Phase2: collision NSError describes the duplicate name");
    }
    unlink([path fileSystemRepresentation]);
}

void testPhase12RunProtocol(void)
{
    testRunProtocolConformance();
    testProtocolMethodsCallableUniformly();
    testMSProvenanceChainPopulated();
    testGenomicProvenanceChainPopulated();
    testGenomicProvenanceChainEmpty();
    testRunsCanonicalAccessor();
    testRunsForSampleCrossModality();
    testRunsOfModality();
    testMixedRunsWriteAPI();
    testMixedRunsNameCollisionRaises();
}
