/*
 * TestProgressSink.m
 * TTI-O Objective-C tests
 *
 * Verifies the TTIOProgressBlock typedef + TTIOProgressDiscard helper
 * + Stage B reader progress hooks (FASTQ, FASTA-unaligned). Mirrors
 * Java's ProgressSinkTest and Python's test_fastq_progress.py /
 * test_fasta_progress.py.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOProgressSink.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Import/TTIOFastqReader.h"
#import "Import/TTIOFastaReader.h"
#import "Import/TTIOBamReader.h"
#import "ValueClasses/TTIOEnums.h"


static NSString *psMakeTempDir(void)
{
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

static void psWriteFile(NSString *path, NSString *contents)
{
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}


// -- TTIOProgressDiscard / typedef coverage ------------------------------

static void testProgressSinkDiscard(void)
{
    TTIOProgressBlock discard = TTIOProgressDiscard();
    PASS(discard != nil, "TTIOProgressDiscard returns a non-nil block");
    // Should be safe to invoke with any args, including the -1 sentinel.
    discard(0, -1);
    discard(100, 100);
    discard(0, 0);
    PASS(YES, "discard block invocations do not crash");
}

static void testProgressBlockTypedefAcceptsCapturedState(void)
{
    __block int64_t lastDone = -42;
    __block int64_t lastTotal = -42;
    __block NSUInteger fires = 0;
    TTIOProgressBlock block = ^(int64_t done, int64_t total) {
        lastDone = done;
        lastTotal = total;
        fires++;
    };
    block(7, -1);
    block(42, 42);
    PASS(fires == 2, "block fires twice");
    PASS(lastDone == 42 && lastTotal == 42, "block captures final args");
}


// -- FASTQ progress hook -------------------------------------------------

static NSString *psFastqRecord(NSUInteger i)
{
    return [NSString stringWithFormat:@"@read_%lu\nACGTACGT\n+\nIIIIIIII\n",
            (unsigned long)i];
}

static void testFastqProgressFires(void)
{
    NSString *tmp = psMakeTempDir();
    NSError *err = nil;

    // Build a small FASTQ — well below the 1000-record interval, so
    // we only expect the final (total, total) fire.
    NSMutableString *small = [NSMutableString string];
    for (NSUInteger i = 0; i < 5; i++) [small appendString:psFastqRecord(i)];
    NSString *smallPath = [tmp stringByAppendingPathComponent:@"small.fq"];
    psWriteFile(smallPath, small);

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    TTIOWrittenGenomicRun *run = [TTIOFastqReader
        readFromPath:smallPath
         forcedPhred:33
          sampleName:@"S1"
            platform:@""
        referenceUri:@""
     acquisitionMode:TTIOAcquisitionModeGenomicWGS
         outDetected:NULL
            progress:cb
               error:&err];
    PASS(run != nil && run.readCount == 5, "FASTQ small read parses with progress");
    PASS(doneVals.count >= 1, "at least one progress fire");
    PASS([doneVals.lastObject longLongValue] == 5,
         "final fire reports total record count");
    PASS([totalVals.lastObject longLongValue] == 5,
         "final fire stamps both done and total");

    // Nil-progress overload still works (forwarded discard).
    TTIOWrittenGenomicRun *run2 = [TTIOFastqReader
        readFromPath:smallPath
         forcedPhred:33
          sampleName:@"S1"
            platform:@""
        referenceUri:@""
     acquisitionMode:TTIOAcquisitionModeGenomicWGS
         outDetected:NULL
            progress:nil
               error:&err];
    PASS(run2 != nil && run2.readCount == 5,
         "nil progress overload still parses");

    // Existing non-progress overload is unchanged.
    NSError *err2 = nil;
    TTIOWrittenGenomicRun *run3 = [TTIOFastqReader
        readFromPath:smallPath
         forcedPhred:33
          sampleName:@"S1"
            platform:@""
        referenceUri:@""
     acquisitionMode:TTIOAcquisitionModeGenomicWGS
         outDetected:NULL
               error:&err2];
    PASS(run3 != nil && run3.readCount == 5,
         "legacy (no progress arg) overload still parses");
}

static void testFastqProgressCadence(void)
{
    NSString *tmp = psMakeTempDir();
    NSError *err = nil;

    // Build a FASTQ with 2500 reads to cross the 1000-record interval
    // boundary twice (fires at 1000 and 2000) and a final at 2500.
    NSMutableString *big = [NSMutableString string];
    for (NSUInteger i = 0; i < 2500; i++) [big appendString:psFastqRecord(i)];
    NSString *bigPath = [tmp stringByAppendingPathComponent:@"big.fq"];
    psWriteFile(bigPath, big);

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    TTIOWrittenGenomicRun *run = [TTIOFastqReader
        readFromPath:bigPath
         forcedPhred:33
          sampleName:@"S1"
            platform:@""
        referenceUri:@""
     acquisitionMode:TTIOAcquisitionModeGenomicWGS
         outDetected:NULL
            progress:cb
               error:&err];
    PASS(run != nil && run.readCount == 2500, "2500 reads parse");
    PASS(doneVals.count == 3,
         "fires: at 1000, at 2000, final (2500, 2500)");
    PASS([doneVals[0] longLongValue] == 1000 &&
         [totalVals[0] longLongValue] == -1,
         "first fire is (1000, -1)");
    PASS([doneVals[1] longLongValue] == 2000 &&
         [totalVals[1] longLongValue] == -1,
         "second fire is (2000, -1)");
    PASS([doneVals[2] longLongValue] == 2500 &&
         [totalVals[2] longLongValue] == 2500,
         "final fire is (2500, 2500)");

    // done values are monotonically non-decreasing.
    for (NSUInteger i = 1; i < doneVals.count; i++) {
        PASS([doneVals[i] longLongValue] >= [doneVals[i - 1] longLongValue],
             "done values are monotonically non-decreasing");
    }
}


// -- FASTA progress hook -------------------------------------------------

static void testFastaUnalignedProgressFires(void)
{
    NSString *tmp = psMakeTempDir();
    NSError *err = nil;

    // Small FASTA — 3 records, below the 1000 interval.
    NSString *small = @">r1\nACGT\n>r2\nGGGG\n>r3\nTTTT\n";
    NSString *smallPath = [tmp stringByAppendingPathComponent:@"small.fa"];
    psWriteFile(smallPath, small);

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    TTIOWrittenGenomicRun *run = [TTIOFastaReader
        readUnalignedFromPath:smallPath
                   sampleName:@"S1"
                     platform:@""
                 referenceUri:@""
              acquisitionMode:TTIOAcquisitionModeGenomicWGS
                     progress:cb
                        error:&err];
    PASS(run != nil && run.readCount == 3,
         "FASTA unaligned read parses with progress");
    PASS(doneVals.count >= 1, "at least one progress fire");
    PASS([doneVals.lastObject longLongValue] == 3,
         "final fire reports total record count");
    PASS([totalVals.lastObject longLongValue] == 3,
         "final fire stamps both done and total");

    // Legacy overload unchanged.
    NSError *err2 = nil;
    TTIOWrittenGenomicRun *run2 = [TTIOFastaReader
        readUnalignedFromPath:smallPath
                   sampleName:@"S1"
                     platform:@""
                 referenceUri:@""
              acquisitionMode:TTIOAcquisitionModeGenomicWGS
                        error:&err2];
    PASS(run2 != nil && run2.readCount == 3,
         "legacy (no progress arg) FASTA overload still parses");
}


// -- BAM reader progress hook (samtools-gated) ---------------------------

static BOOL psSamtoolsAvailable(void)
{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/env";
    t.arguments = @[@"samtools", @"--version"];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; }
    @catch (NSException *e) { return NO; }
    return t.terminationStatus == 0;
}

static void testBamReaderProgressFires(void)
{
    if (!psSamtoolsAvailable()) {
        PASS(YES, "BAM reader progress: samtools unavailable (skipped)");
        return;
    }
    NSString *tmp = psMakeTempDir();
    NSUInteger n = 5000;
    NSMutableString *sam = [NSMutableString string];
    [sam appendString:@"@HD\tVN:1.6\tSO:unsorted\n@SQ\tSN:chr1\tLN:1000\n"];
    for (NSUInteger i = 0; i < n; i++) {
        [sam appendFormat:@"r%06lu\t4\t*\t0\t0\t*\t*\t0\t0\tACGTACGT\tIIIIIIII\n",
                          (unsigned long)i];
    }
    NSString *samPath = [tmp stringByAppendingPathComponent:@"synth.sam"];
    psWriteFile(samPath, sam);

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };

    NSError *err = nil;
    TTIOBamReader *reader = [[TTIOBamReader alloc] initWithPath:samPath];
    TTIOWrittenGenomicRun *run =
        [reader toGenomicRunWithName:nil region:nil sampleName:nil
                            progress:cb error:&err];
    PASS(run != nil, "BAM reader progress: SAM parses via samtools");
    PASS(doneVals.count >= 1, "BAM reader progress: at least one fire");
    PASS([doneVals.lastObject longLongValue] == (int64_t)n,
         "BAM reader progress: final fire reports total read count");
    PASS([totalVals.lastObject longLongValue] == (int64_t)n,
         "BAM reader progress: final fire stamps total == read count");
}


// Public entry point — called from TTIOTestRunner.m.
void testProgressSink(void)
{
    testProgressSinkDiscard();
    testProgressBlockTypedefAcceptsCapturedState();
    testFastqProgressFires();
    testFastqProgressCadence();
    testFastaUnalignedProgressFires();
    testBamReaderProgressFires();
}
