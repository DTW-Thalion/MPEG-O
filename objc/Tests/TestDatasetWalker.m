/*
 * TestDatasetWalker — exercises TTIODatasetWalker + visitor protocol.
 *
 * Acceptance:
 *   1. Unfiltered walk emits the expected event sequence
 *      (StreamHeader → DatasetHeaders → AUs → EndOfDataset → EndOfStream).
 *   2. ms_level filter shrinks the AU stream to matching subset.
 *   3. max_au cap is honoured.
 *   4. Walker is reusable: two walks of the same dataset produce
 *      identical event sequences.
 *   5. A visitor that implements only the AU callback receives only
 *      those events (other events skipped via respondsToSelector:).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Transport/TTIODatasetWalker.h"
#import "Transport/TTIOAccessUnit.h"
#import "Transport/TTIOAUFilter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Image/TTIOMSImage.h"
#import "Image/TTIORamanImage.h"
#import "Image/TTIOIRImage.h"
#import "ValueClasses/TTIOEnums.h"
#import "TTIOV011FixtureBuilder.h"


static NSString *walkerTmp(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/ttio_walker_%d_%@",
            (int)getpid(), n];
}
static void rmFile(NSString *p) {
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

static NSData *f64leW(const double *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *i32arrW(const int32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u32arrW(const uint32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u64arrW(const uint64_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}

// 1 run × 5 spectra: alternating ms_level (1,2,1,2,1) and rts 1..5.
static BOOL buildWalkerFixture(NSString *path, NSError **error)
{
    NSUInteger n = 5, p = 3, total = n * p;
    double mz[15], intensity[15];
    for (NSUInteger i = 0; i < total; i++) {
        mz[i]        = 100.0 + i;
        intensity[i] = 100.0 * (i + 1);
    }
    uint64_t offsets[5] = {0, 3, 6, 9, 12};
    uint32_t lengths[5] = {3, 3, 3, 3, 3};
    double rts[5]       = {1.0, 2.0, 3.0, 4.0, 5.0};
    int32_t msLevels[5] = {1, 2, 1, 2, 1};
    int32_t polarities[5] = {1, 1, 1, 1, 1};
    double pmzs[5]      = {0.0, 510.0, 0.0, 530.0, 0.0};
    int32_t pcs[5]      = {0, 2, 0, 2, 0};
    double bpis[5];
    for (NSUInteger i = 0; i < n; i++) {
        double best = 0.0;
        for (NSUInteger k = 0; k < p; k++) {
            double v = intensity[i * p + k];
            if (v > best) best = v;
        }
        bpis[i] = best;
    }
    TTIOWrittenRun *run =
        [[TTIOWrittenRun alloc]
            initWithSpectrumClassName:@"TTIOMassSpectrum"
                       acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                           channelData:@{@"mz":        f64leW(mz, total),
                                          @"intensity": f64leW(intensity, total)}
                                offsets:u64arrW(offsets, n)
                                lengths:u32arrW(lengths, n)
                         retentionTimes:f64leW(rts, n)
                               msLevels:i32arrW(msLevels, n)
                              polarities:i32arrW(polarities, n)
                            precursorMzs:f64leW(pmzs, n)
                        precursorCharges:i32arrW(pcs, n)
                     basePeakIntensities:f64leW(bpis, n)];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"walker fixture"
                                 isaInvestigationId:@"ISA-WALKER"
                                             msRuns:@{@"runA": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}


// Recording visitor: every event lands in a string-tagged array.
@interface RecordingWalkerVisitor : NSObject <TTIOTransportEventVisitor>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, strong) NSMutableArray<TTIOAccessUnit *> *aus;
@end
@implementation RecordingWalkerVisitor
- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
        _aus = [NSMutableArray array];
    }
    return self;
}

- (void)walker:(TTIODatasetWalker *)w
visitStreamHeaderWithFormatVersion:(NSString *)v title:(NSString *)t
                  isaInvestigation:(NSString *)isa
                           features:(NSArray<NSString *> *)f
                         nDatasets:(uint16_t)n
{
    (void)w; (void)v; (void)t; (void)isa; (void)f;
    [_events addObject:[NSString stringWithFormat:@"stream:%u", n]];
}

- (void)walker:(TTIODatasetWalker *)w
visitDatasetHeaderWithDatasetId:(uint16_t)did
                            name:(NSString *)name
                 acquisitionMode:(uint8_t)am
                   spectrumClass:(NSString *)sc
                    channelNames:(NSArray<NSString *> *)ch
                  instrumentJSON:(NSString *)j
                expectedAUCount:(uint32_t)cnt
{
    (void)w; (void)am; (void)sc; (void)ch; (void)j;
    [_events addObject:[NSString stringWithFormat:@"dsh:%u/%@/%u",
                         did, name, cnt]];
}

- (void)walker:(TTIODatasetWalker *)w
 visitAccessUnit:(TTIOAccessUnit *)au
       datasetId:(uint16_t)did
      auSequence:(uint32_t)seq
{
    (void)w;
    [_aus addObject:au];
    [_events addObject:[NSString stringWithFormat:@"au:%u/%u", did, seq]];
}

- (void)walker:(TTIODatasetWalker *)w
visitEndOfDatasetWithDatasetId:(uint16_t)did
                finalAUSequence:(uint32_t)seq
{
    (void)w;
    [_events addObject:[NSString stringWithFormat:@"eod:%u/%u", did, seq]];
}

- (void)walkerVisitEndOfStream:(TTIODatasetWalker *)w
{
    (void)w;
    [_events addObject:@"eos"];
}
@end


// #140: Recording visitor that also captures the v0.11 prelude events.
// Same string-tag scheme as RecordingWalkerVisitor.
@interface V011RecordingVisitor : NSObject <TTIOTransportEventVisitor>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, strong) NSMutableArray *refs;
@property (nonatomic, strong) NSMutableArray *images;
@property (nonatomic, strong) NSMutableArray *ramans;
@property (nonatomic, strong) NSMutableArray *irs;
@property (nonatomic, strong) NSArray<TTIOIdentification *> *idents;
@property (nonatomic, strong) NSArray<TTIOQuantification *> *quants;
@property (nonatomic, strong) NSArray<TTIOSubject *> *subjects;
@property (nonatomic, strong) NSArray<TTIOSample *> *samples;
@property (nonatomic, strong) NSArray<TTIOProvenanceRecord *> *prov;
@property (nonatomic, strong) NSString *algo;
@property (nonatomic) NSUInteger msAUCount;
@property (nonatomic) NSUInteger genomicAUCount;
@end
@implementation V011RecordingVisitor
- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
        _refs   = [NSMutableArray array];
        _images = [NSMutableArray array];
        _ramans = [NSMutableArray array];
        _irs    = [NSMutableArray array];
    }
    return self;
}
- (void)walker:(TTIODatasetWalker *)w
visitStreamHeaderWithFormatVersion:(NSString *)v title:(NSString *)t
                  isaInvestigation:(NSString *)isa
                           features:(NSArray<NSString *> *)f
                         nDatasets:(uint16_t)n
{
    (void)w; (void)v; (void)t; (void)isa; (void)f; (void)n;
    [_events addObject:@"stream"];
}
- (void)walker:(TTIODatasetWalker *)w
visitEncryptionAlgorithm:(NSString *)algo
{
    (void)w;
    _algo = [algo copy];
    [_events addObject:@"encryption"];
}
- (void)walker:(TTIODatasetWalker *)w
visitDatasetProvenance:(NSArray<TTIOProvenanceRecord *> *)records
{
    (void)w;
    _prov = [records copy];
    [_events addObject:@"provenance"];
}
- (void)walker:(TTIODatasetWalker *)w
visitSubjectMetadata:(NSArray<TTIOSubject *> *)rows
{
    (void)w;
    _subjects = [rows copy];
    [_events addObject:@"subjects"];
}
- (void)walker:(TTIODatasetWalker *)w
visitSampleMetadata:(NSArray<TTIOSample *> *)rows
{
    (void)w;
    _samples = [rows copy];
    [_events addObject:@"samples"];
}
- (void)walker:(TTIODatasetWalker *)w
visitReferenceGroup:(TTIOReferenceImport *)reference
{
    (void)w;
    if (reference) [_refs addObject:reference];
    [_events addObject:@"reference"];
}
- (void)walker:(TTIODatasetWalker *)w
visitImage:(TTIOMSImage *)image
{
    (void)w;
    if (image) [_images addObject:image];
    [_events addObject:@"image"];
}
- (void)walker:(TTIODatasetWalker *)w
visitRamanImage:(TTIORamanImage *)image
{
    (void)w;
    if (image) [_ramans addObject:image];
    [_events addObject:@"raman"];
}
- (void)walker:(TTIODatasetWalker *)w
visitIRImage:(TTIOIRImage *)image
{
    (void)w;
    if (image) [_irs addObject:image];
    [_events addObject:@"ir"];
}
- (void)walker:(TTIODatasetWalker *)w
visitIdentificationsTable:(NSArray<TTIOIdentification *> *)rows
{
    (void)w;
    _idents = [rows copy];
    [_events addObject:@"identifications"];
}
- (void)walker:(TTIODatasetWalker *)w
visitQuantificationsTable:(NSArray<TTIOQuantification *> *)rows
{
    (void)w;
    _quants = [rows copy];
    [_events addObject:@"quantifications"];
}
- (void)walker:(TTIODatasetWalker *)w
visitDatasetHeaderWithDatasetId:(uint16_t)did
                            name:(NSString *)name
                 acquisitionMode:(uint8_t)am
                   spectrumClass:(NSString *)sc
                    channelNames:(NSArray<NSString *> *)ch
                  instrumentJSON:(NSString *)j
                expectedAUCount:(uint32_t)cnt
{
    (void)w; (void)did; (void)name; (void)am; (void)ch; (void)j; (void)cnt;
    [_events addObject:[sc isEqualToString:@"TTIOGenomicRead"]
                       ? @"dsh-genomic" : @"dsh-ms"];
}
- (void)walker:(TTIODatasetWalker *)w
 visitAccessUnit:(TTIOAccessUnit *)au
       datasetId:(uint16_t)did
      auSequence:(uint32_t)seq
{
    (void)w; (void)did; (void)seq;
    if (au.spectrumClass == 5) _genomicAUCount++;
    else                       _msAUCount++;
}
- (void)walker:(TTIODatasetWalker *)w
visitEndOfDatasetWithDatasetId:(uint16_t)did
                finalAUSequence:(uint32_t)seq
{
    (void)w; (void)did; (void)seq;
    [_events addObject:@"eod"];
}
- (void)walkerVisitEndOfStream:(TTIODatasetWalker *)w
{
    (void)w;
    [_events addObject:@"eos"];
}
@end


// AU-only visitor: implements only the AU callback.
@interface AUOnlyVisitor : NSObject <TTIOTransportEventVisitor>
@property (nonatomic) NSUInteger auCount;
@end
@implementation AUOnlyVisitor
- (void)walker:(TTIODatasetWalker *)w
 visitAccessUnit:(TTIOAccessUnit *)au
       datasetId:(uint16_t)did
      auSequence:(uint32_t)seq
{
    (void)w; (void)au; (void)did; (void)seq;
    _auCount++;
}
@end


void testDatasetWalker(void)
{
    @autoreleasepool {
        NSString *path = walkerTmp(@"fixture.tio");
        rmFile(path);
        NSError *err = nil;
        BOOL ok = buildWalkerFixture(path, &err);
        PASS(ok, "walker fixture built");
        if (!ok) {
            fprintf(stderr, "fixture build failed: %s\n",
                    err.localizedDescription.UTF8String);
            return;
        }
        TTIOSpectralDataset *dataset =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(dataset != nil, "fixture re-opens cleanly");
        if (!dataset) {
            rmFile(path);
            return;
        }

        // ── 1. Unfiltered walk: full event sequence ────────────────
        {
            RecordingWalkerVisitor *v = [[RecordingWalkerVisitor alloc] init];
            TTIODatasetWalker *w = [[TTIODatasetWalker alloc] init];
            BOOL walked = [w walkDataset:dataset filter:nil visitor:v error:NULL];
            PASS(walked, "unfiltered walk returns YES");
            PASS(v.aus.count == 5, "unfiltered walk: 5 AccessUnits");
            PASS([v.events.firstObject hasPrefix:@"stream:"],
                 "first event is StreamHeader");
            PASS([v.events.lastObject isEqualToString:@"eos"],
                 "last event is EndOfStream");
            BOOL hasDsh = NO, hasEod = NO;
            for (NSString *e in v.events) {
                if ([e hasPrefix:@"dsh:"]) hasDsh = YES;
                if ([e hasPrefix:@"eod:"]) hasEod = YES;
            }
            PASS(hasDsh && hasEod,
                 "walk emits DatasetHeader and EndOfDataset");
        }

        // ── 2. ms_level=1 filter: keeps indexes 0,2,4 ──────────────
        {
            TTIOAUFilter *f = [[TTIOAUFilter alloc] init];
            [f setValue:@1 forKey:@"msLevel"];
            RecordingWalkerVisitor *v = [[RecordingWalkerVisitor alloc] init];
            TTIODatasetWalker *w = [[TTIODatasetWalker alloc] init];
            [w walkDataset:dataset filter:f visitor:v error:NULL];
            PASS(v.aus.count == 3, "ms_level=1 filter: 3 AUs");
        }

        // ── 3. max_au cap ──────────────────────────────────────────
        {
            TTIOAUFilter *f = [[TTIOAUFilter alloc] init];
            [f setValue:@2 forKey:@"maxAU"];
            RecordingWalkerVisitor *v = [[RecordingWalkerVisitor alloc] init];
            TTIODatasetWalker *w = [[TTIODatasetWalker alloc] init];
            [w walkDataset:dataset filter:f visitor:v error:NULL];
            PASS(v.aus.count == 2, "max_au=2 cap: exactly 2 AUs");
        }

        // ── 4. Walker reusable ─────────────────────────────────────
        {
            TTIODatasetWalker *w = [[TTIODatasetWalker alloc] init];
            RecordingWalkerVisitor *v1 = [[RecordingWalkerVisitor alloc] init];
            RecordingWalkerVisitor *v2 = [[RecordingWalkerVisitor alloc] init];
            [w walkDataset:dataset filter:nil visitor:v1 error:NULL];
            [w walkDataset:dataset filter:nil visitor:v2 error:NULL];
            PASS([v1.events isEqualToArray:v2.events],
                 "walker reusable: two walks → identical event sequences");
        }

        // ── 5. AU-only visitor receives only AU events ─────────────
        {
            AUOnlyVisitor *v = [[AUOnlyVisitor alloc] init];
            TTIODatasetWalker *w = [[TTIODatasetWalker alloc] init];
            BOOL walked = [w walkDataset:dataset filter:nil visitor:v error:NULL];
            PASS(walked, "AU-only visitor walk returns YES");
            PASS(v.auCount == 5,
                 "AU-only visitor: 5 AU callbacks, other events skipped");
        }

        rmFile(path);
    }
}


// #140: v0.11 prelude + genomic AU emission via buildEverythingAtPath:.
// Asserts the walker now visits every first-class accessor (refs +
// subjects + samples + provenance + image + identifications +
// quantifications + encryption + genomic AUs) in transport-spec §5.4
// order, before any DatasetHeader event, with the visitor invoked
// exactly once per non-empty accessor.
void testDatasetWalkerV011Prelude(void)
{
    @autoreleasepool {
        NSString *path = walkerTmp(@"v011_everything.tio");
        rmFile(path);
        NSError *err = nil;
        BOOL ok = [TTIOV011FixtureBuilder buildEverythingAtPath:path
                                                          error:&err];
        PASS(ok, "v0.11 'everything' fixture built");
        if (!ok) {
            fprintf(stderr, "fixture build failed: %s\n",
                    err.localizedDescription.UTF8String);
            return;
        }
        TTIOSpectralDataset *dataset =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(dataset != nil, "v0.11 fixture re-opens cleanly");
        if (!dataset) {
            rmFile(path);
            return;
        }

        V011RecordingVisitor *v = [[V011RecordingVisitor alloc] init];
        TTIODatasetWalker *w = [[TTIODatasetWalker alloc] init];
        BOOL walked = [w walkDataset:dataset filter:nil visitor:v error:NULL];
        PASS(walked, "v0.11 walk returns YES");

        // Locate the prelude events. They MUST all sit between the
        // StreamHeader event and the first DatasetHeader event.
        NSUInteger streamIdx = NSNotFound, firstDshIdx = NSNotFound;
        for (NSUInteger i = 0; i < v.events.count; i++) {
            NSString *e = v.events[i];
            if (streamIdx == NSNotFound && [e isEqualToString:@"stream"]) {
                streamIdx = i;
            } else if (firstDshIdx == NSNotFound &&
                       ([e isEqualToString:@"dsh-ms"] ||
                        [e isEqualToString:@"dsh-genomic"])) {
                firstDshIdx = i;
                break;
            }
        }
        PASS(streamIdx != NSNotFound, "found StreamHeader event");
        PASS(firstDshIdx != NSNotFound && firstDshIdx > streamIdx,
             "found DatasetHeader event after StreamHeader");

        // Collect prelude slice.
        NSArray *prelude =
            [v.events subarrayWithRange:NSMakeRange(streamIdx + 1,
                                                     firstDshIdx - streamIdx - 1)];
        // buildEverythingAtPath: populates every accessor: encryption,
        // provenance, subjects, samples, references, msImage,
        // identifications, quantifications. Raman/IR are absent in the
        // 'everything' fixture (they have their own dedicated fixtures).
        NSArray *expected = @[@"encryption", @"provenance",
                              @"subjects", @"samples", @"reference",
                              @"image", @"identifications",
                              @"quantifications"];
        PASS([prelude isEqualToArray:expected],
             "v0.11 prelude events are in §5.4 order");

        // Sanity-check the accessor counts and content.
        PASS(v.refs.count == 1, "visitor saw 1 reference group");
        PASS(v.images.count == 1, "visitor saw 1 MS image");
        PASS(v.idents.count == 2, "visitor saw 2 identification rows");
        PASS(v.quants.count == 2, "visitor saw 2 quantification rows");
        PASS(v.subjects.count == 2, "visitor saw 2 subjects");
        PASS(v.samples.count == 3, "visitor saw 3 samples");
        PASS(v.prov.count == 2, "visitor saw 2 provenance records");
        PASS([v.algo isEqualToString:@"aes-256-gcm"],
             "visitor saw encryption algorithm");

        // Genomic AU emission was the second half of the #140 fix —
        // the 'everything' fixture has 1 genomic run with 4 reads.
        PASS(v.msAUCount == 5, "5 MS AUs walked");
        PASS(v.genomicAUCount == 4, "4 genomic AUs walked");

        rmFile(path);
    }
}
