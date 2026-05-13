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
#import "ValueClasses/TTIOEnums.h"


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
