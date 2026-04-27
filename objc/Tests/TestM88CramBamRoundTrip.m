/*
 * TestM88CramBamRoundTrip.m — ObjC TTIOCramReader / TTIOBamWriter / TTIOCramWriter.
 *
 * Mirrors the 14 cases in python/tests/test_m88_cram_bam_round_trip.py.
 * Skips cleanly when `samtools` is not on PATH (HANDOFF Gotcha §158).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Import/TTIOBamReader.h"
#import "Import/TTIOCramReader.h"
#import "Export/TTIOBamWriter.h"
#import "Export/TTIOCramWriter.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

static NSString *const kBamPath  =
    @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/m88_test.bam";
static NSString *const kCramPath =
    @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/m88_test.cram";
static NSString *const kRefPath  =
    @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/m88_test_reference.fa";

// Expected post-sort coordinate order from the SAM source.
static NSArray<NSString *> *m88ExpectedReadNames(void)
{
    return @[@"m88r001", @"m88r002", @"m88r003", @"m88r004", @"m88r005"];
}
static NSArray<NSNumber *> *m88ExpectedPositions(void)
{
    return @[@101, @201, @301, @401, @201];
}
static NSArray<NSString *> *m88ExpectedChromosomes(void)
{
    return @[@"chr1", @"chr1", @"chr1", @"chr1", @"chr2"];
}

// ── Skip helper ──────────────────────────────────────────────────────
static BOOL m88SamtoolsAvailable(void)
{
    NSString *path = [[NSProcessInfo processInfo] environment][@"PATH"];
    if (path.length == 0) return NO;
    NSArray *parts = [path componentsSeparatedByString:@":"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bin = nil;
    for (NSString *dir in parts) {
        if (dir.length == 0) continue;
        NSString *full = [dir stringByAppendingPathComponent:@"samtools"];
        if ([fm isExecutableFileAtPath:full]) { bin = full; break; }
    }
    if (!bin) return NO;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = bin;
    t.arguments = @[@"--version"];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError  = p;
    @try { [t launch]; }
    @catch (NSException *e) { (void)e; return NO; }
    [t waitUntilExit];
    [[p fileHandleForReading] readDataToEndOfFile];
    return t.terminationStatus == 0;
}

// Mints a temp directory under /tmp/ttio_m88_<pid>_<seq>/. Caller must
// rm -rf it after use.
static NSString *m88MakeTempDir(NSString *tag)
{
    static int seq = 0;
    seq++;
    NSString *dir = [NSString stringWithFormat:@"/tmp/ttio_m88_%@_%d_%d",
                                                tag, (int)getpid(), seq];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dir error:NULL];
    [fm createDirectoryAtPath:dir
   withIntermediateDirectories:YES
                    attributes:nil
                         error:NULL];
    return dir;
}

static void m88CleanupDir(NSString *dir)
{
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
}

// ── Build a small synthetic WrittenGenomicRun for writer tests. ─────
// 3 reads, all aligned to chr1 (matching the m88 synthetic reference).
static TTIOWrittenGenomicRun *m88BuildSynthRun(BOOL mateChromSame, BOOL matePosNegOne)
{
    NSMutableData *seqs = [NSMutableData data];
    NSMutableData *quals = [NSMutableData data];
    const char *seqChunk = "ACGT";  // 25 reps × 4 = 100 bytes per read
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 25; j++) {
            [seqs appendBytes:seqChunk length:4];
        }
        char qbuf[100];
        memset(qbuf, 'I', 100);
        [quals appendBytes:qbuf length:100];
    }

    NSMutableData *offsets = [NSMutableData data];
    NSMutableData *lengths = [NSMutableData data];
    NSMutableData *positions = [NSMutableData data];
    NSMutableData *mapqs = [NSMutableData data];
    NSMutableData *flags = [NSMutableData data];
    NSMutableData *matePos = [NSMutableData data];
    NSMutableData *tlens = [NSMutableData data];

    int64_t posVals[3] = {101, 201, 301};
    for (int i = 0; i < 3; i++) {
        uint64_t off = (uint64_t)(i * 100);
        uint32_t len = 100;
        uint8_t mq = 60;
        uint32_t fl = 0;
        int64_t mp = matePosNegOne ? -1 : 0;
        int32_t tl = 0;
        [offsets appendBytes:&off length:sizeof(uint64_t)];
        [lengths appendBytes:&len length:sizeof(uint32_t)];
        [positions appendBytes:&posVals[i] length:sizeof(int64_t)];
        [mapqs appendBytes:&mq length:sizeof(uint8_t)];
        [flags appendBytes:&fl length:sizeof(uint32_t)];
        [matePos appendBytes:&mp length:sizeof(int64_t)];
        [tlens appendBytes:&tl length:sizeof(int32_t)];
    }

    NSArray<NSString *> *cigars = @[@"100M", @"100M", @"100M"];
    NSArray<NSString *> *names = @[@"s001", @"s002", @"s003"];
    NSArray<NSString *> *chroms = @[@"chr1", @"chr1", @"chr1"];
    NSArray<NSString *> *mateChroms = mateChromSame
        ? @[@"chr1", @"chr1", @"chr1"]
        : @[@"*", @"*", @"*"];

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"chr1"
                       platform:@"ILLUMINA"
                     sampleName:@"M88_SYNTH"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seqs
                      qualities:quals
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
}

// ── Test 1: CramReader on the M88 fixture returns 5 reads ──────────
static void m88_test01_cramReadFull(void)
{
    TTIOCramReader *r = [[TTIOCramReader alloc] initWithPath:kCramPath
                                              referenceFasta:kRefPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *run = [r toGenomicRunWithName:nil region:nil
                                              sampleName:nil error:&err];
    PASS(run != nil, "M88 #1: CramReader returns a run (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");
    PASS(run.readNames.count == 5, "M88 #1: read_count == 5");
    PASS([run.readNames isEqualToArray:m88ExpectedReadNames()],
         "M88 #1: read_names in expected order");
    PASS([run.chromosomes isEqualToArray:m88ExpectedChromosomes()],
         "M88 #1: chromosomes match expected (chr1×4, chr2)");
    PASS([run.sampleName isEqualToString:@"M88_TEST_SAMPLE"],
         "M88 #1: sample_name from @RG SM");
    PASS([run.platform isEqualToString:@"ILLUMINA"],
         "M88 #1: platform from @RG PL");

    const int64_t *p = run.positionsData.bytes;
    NSArray *exp = m88ExpectedPositions();
    BOOL ok = (run.positionsData.length == 5 * sizeof(int64_t));
    for (NSUInteger i = 0; ok && i < 5; i++) {
        if (p[i] != [exp[i] longLongValue]) ok = NO;
    }
    PASS(ok, "M88 #1: positions array == expected");
}

// ── Test 2: CRAM region filter ──────────────────────────────────────
static void m88_test02_cramReadRegion(void)
{
    TTIOCramReader *r = [[TTIOCramReader alloc] initWithPath:kCramPath
                                              referenceFasta:kRefPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *run = [r toGenomicRunWithName:nil
                                                   region:@"chr1:100-500"
                                               sampleName:nil error:&err];
    PASS(run != nil, "M88 #2: region filter call succeeds (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");
    PASS(run.readNames.count == 4, "M88 #2: chr1 region returns 4 reads");
    BOOL allChr1 = YES;
    for (NSString *c in run.chromosomes) {
        if (![c isEqualToString:@"chr1"]) { allChr1 = NO; break; }
    }
    PASS(allChr1, "M88 #2: all returned reads on chr1");
}

// ── Test 3: BAM write basic round-trip ──────────────────────────────
static void m88_test03_bamWriteBasic(void)
{
    NSString *dir = m88MakeTempDir(@"bw");
    NSString *out = [dir stringByAppendingPathComponent:@"round_trip.bam"];

    TTIOBamReader *src = [[TTIOBamReader alloc] initWithPath:kBamPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *srcRun = [src toGenomicRunWithName:nil region:nil
                                                   sampleName:nil error:&err];
    PASS(srcRun != nil, "M88 #3: source BAM read OK");

    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:out];
    BOOL ok = [w writeRun:srcRun provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #3: BAM write succeeded (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOBamReader *back = [[TTIOBamReader alloc] initWithPath:out];
    TTIOWrittenGenomicRun *backRun = [back toGenomicRunWithName:nil region:nil
                                                     sampleName:nil error:&err];
    PASS(backRun != nil, "M88 #3: re-read BAM succeeded");
    PASS(backRun.readNames.count == srcRun.readNames.count,
         "M88 #3: read count round-trips");

    NSArray *backSorted = [backRun.readNames sortedArrayUsingSelector:@selector(compare:)];
    NSArray *srcSorted = [srcRun.readNames sortedArrayUsingSelector:@selector(compare:)];
    PASS([backSorted isEqualToArray:srcSorted],
         "M88 #3: sorted read_names equal across round-trip");

    m88CleanupDir(dir);
}

// ── Test 4: BAM write unsorted preserves input order ───────────────
static void m88_test04_bamWriteUnsorted(void)
{
    NSString *dir = m88MakeTempDir(@"bwu");
    NSString *out = [dir stringByAppendingPathComponent:@"unsorted.bam"];

    TTIOWrittenGenomicRun *src = m88BuildSynthRun(NO, NO);
    NSError *err = nil;
    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:out];
    BOOL ok = [w writeRun:src provenanceRecords:nil sort:NO error:&err];
    PASS(ok, "M88 #4: unsorted BAM write OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOBamReader *back = [[TTIOBamReader alloc] initWithPath:out];
    TTIOWrittenGenomicRun *backRun = [back toGenomicRunWithName:nil region:nil
                                                     sampleName:nil error:&err];
    PASS(backRun != nil, "M88 #4: re-read unsorted BAM OK");
    PASS([backRun.readNames isEqualToArray:src.readNames],
         "M88 #4: unsorted output preserves input read order");

    m88CleanupDir(dir);
}

// ── Test 5: BAM write with explicit provenance record ──────────────
static void m88_test05_bamWriteWithProvenance(void)
{
    NSString *dir = m88MakeTempDir(@"bwp");
    NSString *out = [dir stringByAppendingPathComponent:@"with_prov.bam"];

    TTIOWrittenGenomicRun *src = m88BuildSynthRun(NO, NO);
    TTIOProvenanceRecord *pr = [[TTIOProvenanceRecord alloc]
        initWithInputRefs:@[]
                 software:@"my_tool"
               parameters:@{@"CL": @"my_tool --opt foo input.fq"}
               outputRefs:@[]
            timestampUnix:0];
    NSError *err = nil;
    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:out];
    BOOL ok = [w writeRun:src provenanceRecords:@[pr] sort:YES error:&err];
    PASS(ok, "M88 #5: BAM write with provenance OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOBamReader *back = [[TTIOBamReader alloc] initWithPath:out];
    TTIOWrittenGenomicRun *backRun = [back toGenomicRunWithName:nil region:nil
                                                     sampleName:nil error:&err];
    PASS(backRun != nil, "M88 #5: re-read OK");
    BOOL found = NO;
    NSString *foundCL = nil;
    for (TTIOProvenanceRecord *p in back.provenanceRecords) {
        if ([p.software isEqualToString:@"my_tool"]) {
            found = YES;
            foundCL = p.parameters[@"CL"];
            break;
        }
    }
    PASS(found, "M88 #5: my_tool @PG entry preserved through round-trip");
    PASS(foundCL && [foundCL rangeOfString:@"my_tool --opt foo input.fq"].location != NSNotFound,
         "M88 #5: my_tool CL: parameter preserved");

    m88CleanupDir(dir);
}

// ── Test 6: CRAM write basic round-trip ────────────────────────────
static void m88_test06_cramWriteBasic(void)
{
    NSString *dir = m88MakeTempDir(@"cw");
    NSString *out = [dir stringByAppendingPathComponent:@"round_trip.cram"];

    TTIOWrittenGenomicRun *src = m88BuildSynthRun(NO, NO);
    NSError *err = nil;
    TTIOCramWriter *w = [[TTIOCramWriter alloc] initWithPath:out
                                              referenceFasta:kRefPath];
    BOOL ok = [w writeRun:src provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #6: CRAM write OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOCramReader *back = [[TTIOCramReader alloc] initWithPath:out
                                                 referenceFasta:kRefPath];
    TTIOWrittenGenomicRun *backRun = [back toGenomicRunWithName:nil region:nil
                                                     sampleName:nil error:&err];
    PASS(backRun != nil, "M88 #6: re-read CRAM OK");
    PASS(backRun.readNames.count == src.readNames.count,
         "M88 #6: read count round-trips through CRAM");

    NSArray *backSorted = [backRun.readNames sortedArrayUsingSelector:@selector(compare:)];
    NSArray *srcSorted = [src.readNames sortedArrayUsingSelector:@selector(compare:)];
    PASS([backSorted isEqualToArray:srcSorted],
         "M88 #6: sorted read_names equal across CRAM round-trip");

    PASS([backRun.sequencesData isEqualToData:src.sequencesData],
         "M88 #6: sequences buffer byte-identical through CRAM");

    m88CleanupDir(dir);
}

// ── Test 7: CRAM written with reference can't be read without it ───
static void m88_test07_cramRequiresReference(void)
{
    NSString *dir = m88MakeTempDir(@"cwr");
    NSString *refDir = [dir stringByAppendingPathComponent:@"refs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:refDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *refCopy = [refDir stringByAppendingPathComponent:@"ref.fa"];
    [[NSFileManager defaultManager] copyItemAtPath:kRefPath
                                            toPath:refCopy error:NULL];

    NSString *out = [dir stringByAppendingPathComponent:@"needs_ref.cram"];
    TTIOWrittenGenomicRun *src = m88BuildSynthRun(NO, NO);
    NSError *err = nil;
    TTIOCramWriter *w = [[TTIOCramWriter alloc] initWithPath:out
                                              referenceFasta:refCopy];
    BOOL ok = [w writeRun:src provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #7: CRAM write with copied ref OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    // Yank the reference out from under samtools.
    [[NSFileManager defaultManager] removeItemAtPath:refCopy error:NULL];
    NSString *fai = [refCopy stringByAppendingPathExtension:@"fai"];
    [[NSFileManager defaultManager] removeItemAtPath:fai error:NULL];
    NSString *altFai = [[refCopy stringByDeletingPathExtension]
                        stringByAppendingPathExtension:@"fa.fai"];
    [[NSFileManager defaultManager] removeItemAtPath:altFai error:NULL];

    // Reading via plain BamReader (no --reference) and with REF_PATH
    // disabled should fail.
    NSString *path = [[NSProcessInfo processInfo] environment][@"PATH"];
    NSString *bin = nil;
    NSArray *parts = [path componentsSeparatedByString:@":"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in parts) {
        if (d.length == 0) continue;
        NSString *full = [d stringByAppendingPathComponent:@"samtools"];
        if ([fm isExecutableFileAtPath:full]) { bin = full; break; }
    }
    PASS(bin != nil, "M88 #7: samtools located");

    NSTask *t = [[NSTask alloc] init];
    t.launchPath = bin;
    t.arguments = @[@"view", @"-h", out];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"REF_PATH"] = @":";
    env[@"REF_CACHE"] = @":";
    t.environment = env;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError  = errPipe;
    @try { [t launch]; }
    @catch (NSException *e) { (void)e; }
    [[outPipe fileHandleForReading] readDataToEndOfFile];
    [[errPipe fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    PASS(t.terminationStatus != 0,
         "M88 #7: samtools view fails on CRAM with reference deleted (status=%d)",
         t.terminationStatus);

    m88CleanupDir(dir);
}

// ── Test 8: BAM → GenomicRun → BAM round trip ──────────────────────
static void m88_test08_roundTripBamToBam(void)
{
    NSString *dir = m88MakeTempDir(@"rtbb");
    NSString *out = [dir stringByAppendingPathComponent:@"rt.bam"];

    TTIOBamReader *srcR = [[TTIOBamReader alloc] initWithPath:kBamPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *src = [srcR toGenomicRunWithName:nil region:nil
                                                 sampleName:nil error:&err];
    PASS(src != nil, "M88 #8: source read OK");

    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:out];
    BOOL ok = [w writeRun:src provenanceRecords:src.readNames.count > 0
                                                  ? srcR.provenanceRecords
                                                  : nil
                                                sort:YES error:&err];
    PASS(ok, "M88 #8: write OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOBamReader *backR = [[TTIOBamReader alloc] initWithPath:out];
    TTIOWrittenGenomicRun *back = [backR toGenomicRunWithName:nil region:nil
                                                   sampleName:nil error:&err];
    PASS(back != nil, "M88 #8: re-read OK");
    PASS(back.readNames.count == src.readNames.count,
         "M88 #8: read count preserved");

    // Per-read field equality, indexed by QNAME.
    NSMutableDictionary *srcByName = [NSMutableDictionary dictionary];
    NSMutableDictionary *backByName = [NSMutableDictionary dictionary];
    const int64_t *sp = src.positionsData.bytes;
    const int64_t *bp = back.positionsData.bytes;
    for (NSUInteger i = 0; i < src.readNames.count; i++) {
        srcByName[src.readNames[i]] = @(sp[i]);
    }
    for (NSUInteger i = 0; i < back.readNames.count; i++) {
        backByName[back.readNames[i]] = @(bp[i]);
    }
    BOOL posOk = YES;
    for (NSString *name in src.readNames) {
        if (![srcByName[name] isEqual:backByName[name]]) { posOk = NO; break; }
    }
    PASS(posOk, "M88 #8: per-name positions equal across round trip");

    m88CleanupDir(dir);
}

// ── Test 9: CRAM → GenomicRun → CRAM round trip ────────────────────
static void m88_test09_roundTripCramToCram(void)
{
    NSString *dir = m88MakeTempDir(@"rtcc");
    NSString *out = [dir stringByAppendingPathComponent:@"rt.cram"];

    TTIOCramReader *srcR = [[TTIOCramReader alloc] initWithPath:kCramPath
                                                 referenceFasta:kRefPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *src = [srcR toGenomicRunWithName:nil region:nil
                                                 sampleName:nil error:&err];
    PASS(src != nil, "M88 #9: source CRAM read OK");

    TTIOCramWriter *w = [[TTIOCramWriter alloc] initWithPath:out
                                              referenceFasta:kRefPath];
    BOOL ok = [w writeRun:src provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #9: CRAM write OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOCramReader *backR = [[TTIOCramReader alloc] initWithPath:out
                                                  referenceFasta:kRefPath];
    TTIOWrittenGenomicRun *back = [backR toGenomicRunWithName:nil region:nil
                                                   sampleName:nil error:&err];
    PASS(back != nil, "M88 #9: re-read CRAM OK");
    PASS(back.readNames.count == src.readNames.count,
         "M88 #9: read count preserved through CRAM round trip");

    NSArray *srcSorted = [src.readNames sortedArrayUsingSelector:@selector(compare:)];
    NSArray *backSorted = [back.readNames sortedArrayUsingSelector:@selector(compare:)];
    PASS([srcSorted isEqualToArray:backSorted],
         "M88 #9: sorted read_names equal");

    m88CleanupDir(dir);
}

// ── Test 10: cross-format BAM <-> CRAM round trip ──────────────────
static void m88_test10_roundTripCrossFormat(void)
{
    NSString *dir = m88MakeTempDir(@"rtcross");
    NSString *cramOut = [dir stringByAppendingPathComponent:@"from_bam.cram"];
    NSString *bamOut  = [dir stringByAppendingPathComponent:@"back_to.bam"];

    TTIOBamReader *srcR = [[TTIOBamReader alloc] initWithPath:kBamPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *src = [srcR toGenomicRunWithName:nil region:nil
                                                 sampleName:nil error:&err];
    PASS(src != nil, "M88 #10: source BAM read OK");

    TTIOCramWriter *cw = [[TTIOCramWriter alloc] initWithPath:cramOut
                                               referenceFasta:kRefPath];
    BOOL ok = [cw writeRun:src provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #10: BAM->CRAM write OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    TTIOCramReader *cr = [[TTIOCramReader alloc] initWithPath:cramOut
                                               referenceFasta:kRefPath];
    TTIOWrittenGenomicRun *viaCram = [cr toGenomicRunWithName:nil region:nil
                                                   sampleName:nil error:&err];
    PASS(viaCram != nil, "M88 #10: re-read CRAM OK");

    TTIOBamWriter *bw = [[TTIOBamWriter alloc] initWithPath:bamOut];
    ok = [bw writeRun:viaCram provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #10: CRAM->BAM write OK");

    TTIOBamReader *finR = [[TTIOBamReader alloc] initWithPath:bamOut];
    TTIOWrittenGenomicRun *final = [finR toGenomicRunWithName:nil region:nil
                                                   sampleName:nil error:&err];
    PASS(final != nil, "M88 #10: final BAM read OK");
    PASS(final.readNames.count == src.readNames.count,
         "M88 #10: read count preserved end-to-end");
    NSArray *srcSorted = [src.readNames sortedArrayUsingSelector:@selector(compare:)];
    NSArray *finSorted = [final.readNames sortedArrayUsingSelector:@selector(compare:)];
    PASS([srcSorted isEqualToArray:finSorted],
         "M88 #10: sorted read_names equal end-to-end");

    m88CleanupDir(dir);
}

// Expose the writer's internal SAM-text builder (not part of the public
// API) so #11 can verify the RNEXT collapse happens in TTI-O's emitted
// stream BEFORE samtools sees it. This mirrors Python's direct call to
// BamWriter._build_sam_text in test_mate_collapse_to_equals.
@interface TTIOBamWriter (TestInternals)
- (NSString *)buildHeaderForRun:(TTIOWrittenGenomicRun *)run
              provenanceRecords:(NSArray<TTIOProvenanceRecord *> *)provenance
                           sort:(BOOL)sort;
- (NSString *)buildAlignmentLinesForRun:(TTIOWrittenGenomicRun *)run;
@end

// ── Test 11: mate-chromosome collapse to '=' on write ──────────────
static void m88_test11_mateCollapseToEquals(void)
{
    // The collapse is a writer-side normalisation in TTI-O's emitted
    // SAM text (Binding Decision §136). We verify by inspecting the
    // SAM text produced before handing to samtools — samtools' on-disk
    // BAM uses internal indices, and `samtools view -h` re-expands the
    // RNEXT shorthand back to the chromosome name when decoding.
    TTIOWrittenGenomicRun *src = m88BuildSynthRun(YES, NO);  // mate==chrom
    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:@"/tmp/unused.bam"];
    NSString *header = [w buildHeaderForRun:src provenanceRecords:@[] sort:NO];
    NSString *aligns = [w buildAlignmentLinesForRun:src];
    NSString *sam = [header stringByAppendingString:aligns];

    NSArray<NSString *> *lines = [sam componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *alignLines = [NSMutableArray array];
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        if ([line hasPrefix:@"@"]) continue;
        [alignLines addObject:line];
    }
    PASS(alignLines.count == 3,
         "M88 #11: writer emits 3 alignment lines (got %lu)",
         (unsigned long)alignLines.count);
    BOOL allEquals = YES;
    for (NSString *line in alignLines) {
        NSArray<NSString *> *cols = [line componentsSeparatedByString:@"\t"];
        if (cols.count < 7 || ![cols[6] isEqualToString:@"="]) {
            allEquals = NO;
            break;
        }
    }
    PASS(allEquals, "M88 #11: every alignment line has RNEXT collapsed to '='");
}

// ── Test 12: mate position -1 mapped to 0 on write ─────────────────
static void m88_test12_matePosNegOneToZero(void)
{
    NSString *dir = m88MakeTempDir(@"pneg");
    NSString *out = [dir stringByAppendingPathComponent:@"pneg1.bam"];

    TTIOWrittenGenomicRun *src = m88BuildSynthRun(NO, YES);  // matePos = -1
    NSError *err = nil;
    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:out];
    BOOL ok = [w writeRun:src provenanceRecords:nil sort:NO error:&err];
    PASS(ok, "M88 #12: BAM write with -1 mate positions OK (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    // Read back and verify all mate positions are 0 (samtools accepts
    // them and they round-trip to 0).
    TTIOBamReader *back = [[TTIOBamReader alloc] initWithPath:out];
    TTIOWrittenGenomicRun *backRun = [back toGenomicRunWithName:nil region:nil
                                                     sampleName:nil error:&err];
    PASS(backRun != nil, "M88 #12: re-read OK");
    const int64_t *mp = backRun.matePositionsData.bytes;
    BOOL allZero = (backRun.matePositionsData.length == 3 * sizeof(int64_t));
    for (NSUInteger i = 0; allZero && i < 3; i++) {
        if (mp[i] != 0) allZero = NO;
    }
    PASS(allZero, "M88 #12: mate_positions all 0 after -1 -> 0 mapping");

    m88CleanupDir(dir);
}

// ── Test 13: CramReader requires reference at construction ─────────
static void m88_test13_cramReaderRequiresReference(void)
{
    // ObjC analogue of pytest.raises(TypeError): we rely on
    // NS_UNAVAILABLE in the header marking initWithPath: as
    // unavailable, and on the proper 2-arg initialiser working.
    // Demonstrate both:
    //  (a) The correct initialiser yields a usable reader.
    //  (b) The reference path is preserved via the property.
    TTIOCramReader *r = [[TTIOCramReader alloc] initWithPath:kCramPath
                                              referenceFasta:kRefPath];
    PASS(r != nil, "M88 #13: 2-arg initWithPath:referenceFasta: returns a reader");
    PASS([r.referenceFasta isEqualToString:kRefPath],
         "M88 #13: referenceFasta property preserves the path");
    PASS([r.path isEqualToString:kCramPath],
         "M88 #13: path property preserves the CRAM path");
}

// ── Test 14: writer output is valid SAM that samtools can re-parse ─
static void m88_test14_writerProducesValidSam(void)
{
    NSString *dir = m88MakeTempDir(@"valid");
    NSString *out = [dir stringByAppendingPathComponent:@"valid.bam"];

    TTIOBamReader *srcR = [[TTIOBamReader alloc] initWithPath:kBamPath];
    NSError *err = nil;
    TTIOWrittenGenomicRun *src = [srcR toGenomicRunWithName:nil region:nil
                                                 sampleName:nil error:&err];
    PASS(src != nil, "M88 #14: source read OK");

    TTIOBamWriter *w = [[TTIOBamWriter alloc] initWithPath:out];
    BOOL ok = [w writeRun:src provenanceRecords:nil sort:YES error:&err];
    PASS(ok, "M88 #14: write OK");

    // Run samtools view -h and parse output.
    NSString *path = [[NSProcessInfo processInfo] environment][@"PATH"];
    NSString *bin = nil;
    for (NSString *d in [path componentsSeparatedByString:@":"]) {
        if (d.length == 0) continue;
        NSString *full = [d stringByAppendingPathComponent:@"samtools"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full]) {
            bin = full; break;
        }
    }
    PASS(bin != nil, "M88 #14: samtools located");

    NSTask *t = [[NSTask alloc] init];
    t.launchPath = bin;
    t.arguments = @[@"view", @"-h", out];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError  = errPipe;
    @try { [t launch]; }
    @catch (NSException *e) { (void)e; }
    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    [[errPipe fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    PASS(t.terminationStatus == 0, "M88 #14: samtools view -h exit 0");

    NSString *samText = [[NSString alloc] initWithData:outData
                                              encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [samText componentsSeparatedByString:@"\n"];
    NSUInteger alignCount = 0;
    BOOL hasHd = NO, hasSq = NO;
    BOOL allEleven = YES;
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        if ([line hasPrefix:@"@"]) {
            if ([line hasPrefix:@"@HD"]) hasHd = YES;
            if ([line hasPrefix:@"@SQ"]) hasSq = YES;
        } else {
            alignCount++;
            NSArray *cols = [line componentsSeparatedByString:@"\t"];
            if (cols.count < 11) allEleven = NO;
        }
    }
    PASS(hasHd, "M88 #14: output has @HD line");
    PASS(hasSq, "M88 #14: output has @SQ line(s)");
    PASS(alignCount == src.readNames.count,
         "M88 #14: alignment line count matches source read count");
    PASS(allEleven, "M88 #14: all alignment lines have >= 11 tab columns");

    m88CleanupDir(dir);
}

// ── Entrypoint ───────────────────────────────────────────────────────
void testM88CramBamRoundTrip(void)
{
    if (!m88SamtoolsAvailable()) {
        PASS(YES, "M88: skipping whole suite — samtools not on PATH");
        return;
    }
    m88_test01_cramReadFull();
    m88_test02_cramReadRegion();
    m88_test03_bamWriteBasic();
    m88_test04_bamWriteUnsorted();
    m88_test05_bamWriteWithProvenance();
    m88_test06_cramWriteBasic();
    m88_test07_cramRequiresReference();
    m88_test08_roundTripBamToBam();
    m88_test09_roundTripCramToCram();
    m88_test10_roundTripCrossFormat();
    m88_test11_mateCollapseToEquals();
    m88_test12_matePosNegOneToZero();
    m88_test13_cramReaderRequiresReference();
    m88_test14_writerProducesValidSam();
}
