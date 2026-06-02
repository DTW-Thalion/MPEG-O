// TTIOReferenceImportWriteToDatasetTests.m — Phase 0 Task 0.10c
// tio-browser. Mirror of the Python WriteToDataset round-trip tests
// (test_reference_import_write_round_trip.py) and the Java
// WriteToDatasetTest, this time exercising the new ObjC public method
// -[TTIOReferenceImport writeToDataset:overwrite:error:].
//
// The on-disk layout produced by writeToDataset is byte-identical to
// what _TTIO_M93_EmbedReferences (TTIOSpectralDataset.m) writes
// for embedReference=YES runs, and to what Python's
// ReferenceImport.write_to_dataset and Java's
// ReferenceImport.writeToDataset emit. Round-trip is verified through
// the existing -[TTIOSpectralDataset references] accessor.
//
// Test isolation note: TTIOSpectralDataset has no public "open
// writable" class method. Tests open a TTIOHDF5Provider directly in
// ReadWrite mode, then attach it to a stub-initialised
// TTIOSpectralDataset via object_setIvar so writeToDataset can reach
// the provider through the public -[TTIOSpectralDataset provider]
// accessor. This is purely a test-only workaround; production callers
// hold the dataset returned by their own writer paths and never need
// the runtime trick.
//
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Testing.h"
#import "Core/TTIOProgressSink.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Providers/TTIOHDF5Provider.h"
#import "Providers/TTIOStorageProtocols.h"
#include <unistd.h>

static NSString *makeTempPathW(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_w2d_%d_%@.tio",
                      (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

/** Seed an empty .tio at path then return a minimally-initialised
 *  TTIOSpectralDataset with a writable HDF5 provider attached via
 *  object_setIvar. Caller must -closeFile when done. */
static TTIOSpectralDataset *makeWritableDatasetForPath(NSString *path,
                                                        NSError **error)
{
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                 title:@"w2d-test"
                                    isaInvestigationId:@"W2D001"
                                                msRuns:@{}
                                       identifications:nil
                                       quantifications:nil
                                     provenanceRecords:nil
                                                 error:error];
    if (!ok) return nil;

    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeReadWrite error:error]) {
        return nil;
    }

    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"w2d-test"
                                isaInvestigationId:@"W2D001"
                                            msRuns:@{}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];

    // Attach the writable provider via direct ivar set so the dataset's
    // public `provider` getter surfaces it for writeToDataset:.
    Ivar provIvar = class_getInstanceVariable([TTIOSpectralDataset class],
                                               "_provider");
    if (provIvar == NULL) return nil;
    object_setIvar(ds, provIvar, p);
    return ds;
}

static void testWriteToDatasetRoundTripsThroughReferences(void)
{
    NSString *path = makeTempPathW(@"round_trip");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    TTIOSpectralDataset *ds = makeWritableDatasetForPath(path, &err);
    PASS(ds != nil && err == nil,
         "1.1.0: writable seed dataset constructed for writeToDataset");

    NSData *chr1 = [@"ACGTACGTACGT" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *chr2 = [@"TTTTAAAACCCC" dataUsingEncoding:NSASCIIStringEncoding];
    TTIOReferenceImport *ri =
        [[TTIOReferenceImport alloc] initWithUri:@"round-trip-v1"
                                     chromosomes:@[@"chr1", @"chr2"]
                                       sequences:@[chr1, chr2]];

    BOOL wrote = [ri writeToDataset:ds error:&err];
    PASS(wrote && err == nil,
         "1.1.0: -writeToDataset:error: succeeds on writable dataset");

    [ds closeFile];

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(opened != nil, "1.1.0: round-trip reopen succeeds");

    NSDictionary<NSString *, TTIOReferenceImport *> *refs = opened.references;
    PASS([refs count] == 1,
         "1.1.0: reopened dataset surfaces exactly one embedded reference");

    TTIOReferenceImport *out = refs[@"round-trip-v1"];
    PASS(out != nil, "1.1.0: 'round-trip-v1' present in -references");
    PASS([out.chromosomes isEqualToArray:(@[@"chr1", @"chr2"])],
         "1.1.0: chromosomes preserved in alphabetic order");
    PASS([[out chromosomeNamed:@"chr1"] isEqualToData:chr1],
         "1.1.0: chr1 sequence round-trips byte-equal");
    PASS([[out chromosomeNamed:@"chr2"] isEqualToData:chr2],
         "1.1.0: chr2 sequence round-trips byte-equal");
    PASS([out totalBases] == 24, "1.1.0: totalBases sums to 24");
    PASS([out.md5 isEqualToData:ri.md5],
         "1.1.0: MD5 preserved verbatim through @md5 attribute");

    [opened closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testWriteToDatasetRejectsDuplicateUriWithoutOverwrite(void)
{
    NSString *path = makeTempPathW(@"dup");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    TTIOSpectralDataset *ds = makeWritableDatasetForPath(path, &err);
    PASS(ds != nil, "1.1.0: writable seed dataset constructed");

    TTIOReferenceImport *ri =
        [[TTIOReferenceImport alloc] initWithUri:@"dup-v1"
                                     chromosomes:@[@"chr1"]
                                       sequences:@[[@"ACGT"
                                                    dataUsingEncoding:NSASCIIStringEncoding]]];

    PASS([ri writeToDataset:ds error:&err],
         "1.1.0: first writeToDataset succeeds");

    err = nil;
    BOOL second = [ri writeToDataset:ds overwrite:NO error:&err];
    PASS(!second,
         "1.1.0: second writeToDataset of same URI without overwrite fails");
    PASS(err != nil,
         "1.1.0: failure populates an NSError");
    PASS([err.localizedDescription rangeOfString:@"already embedded"].location
            != NSNotFound,
         "1.1.0: error message mentions 'already embedded'");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testWriteToDatasetOverwriteReplacesExistingReference(void)
{
    NSString *path = makeTempPathW(@"overwrite");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    TTIOSpectralDataset *ds = makeWritableDatasetForPath(path, &err);
    PASS(ds != nil, "1.1.0: writable seed dataset constructed");

    TTIOReferenceImport *first =
        [[TTIOReferenceImport alloc] initWithUri:@"overwrite-v1"
                                     chromosomes:@[@"chr1"]
                                       sequences:@[[@"AAAA"
                                                    dataUsingEncoding:NSASCIIStringEncoding]]];

    NSData *chr1New = [@"CCCC" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *chr2New = [@"GGGG" dataUsingEncoding:NSASCIIStringEncoding];
    TTIOReferenceImport *second =
        [[TTIOReferenceImport alloc] initWithUri:@"overwrite-v1"
                                     chromosomes:@[@"chr1", @"chr2"]
                                       sequences:@[chr1New, chr2New]];

    PASS([first writeToDataset:ds error:&err],
         "1.1.0: first writeToDataset succeeds");
    PASS([second writeToDataset:ds overwrite:YES error:&err],
         "1.1.0: writeToDataset with overwrite=YES replaces the first reference");

    [ds closeFile];

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(opened != nil, "1.1.0: reopen after overwrite succeeds");

    NSDictionary<NSString *, TTIOReferenceImport *> *refs = opened.references;
    PASS([refs count] == 1,
         "1.1.0: still exactly one embedded reference after overwrite");

    TTIOReferenceImport *out = refs[@"overwrite-v1"];
    PASS(out != nil, "1.1.0: 'overwrite-v1' still present");
    PASS([out.chromosomes isEqualToArray:(@[@"chr1", @"chr2"])],
         "1.1.0: post-overwrite chromosomes match the new content");
    PASS([[out chromosomeNamed:@"chr1"] isEqualToData:chr1New],
         "1.1.0: chr1 reflects overwritten content");
    PASS([[out chromosomeNamed:@"chr2"] isEqualToData:chr2New],
         "1.1.0: chr2 reflects overwritten content");
    PASS([out.md5 isEqualToData:second.md5],
         "1.1.0: MD5 reflects overwritten content");

    [opened closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testWriteToDatasetProgressFires(void)
{
    NSError *err = nil;
    NSString *path = makeTempPathW(@"progress");
    TTIOSpectralDataset *ds = makeWritableDatasetForPath(path, &err);
    PASS(ds != nil, "progress: writable dataset created");

    TTIOReferenceImport *ri = [[TTIOReferenceImport alloc]
        initWithUri:@"prog-v1"
        chromosomes:@[@"chr1", @"chr2", @"chr3"]
          sequences:@[[@"ACGT" dataUsingEncoding:NSUTF8StringEncoding],
                      [@"GGGG" dataUsingEncoding:NSUTF8StringEncoding],
                      [@"TTTT" dataUsingEncoding:NSUTF8StringEncoding]]];

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };

    BOOL ok = [ri writeToDataset:ds overwrite:NO progress:cb error:&err];
    PASS(ok, "progress: writeToDataset:overwrite:progress:error: succeeds");
    // (0,3),(1,3),(2,3),(3,3): N+1 fires, total always 3.
    PASS(doneVals.count == 4, "progress: N+1 (=4) callbacks fired");
    PASS([doneVals.firstObject longLongValue] == 0
         && [totalVals.firstObject longLongValue] == 3,
         "progress: first fire is (0, N)");
    PASS([doneVals.lastObject longLongValue] == 3
         && [totalVals.lastObject longLongValue] == 3,
         "progress: last fire is (N, N)");

    // Legacy (no-progress) overload still works.
    NSString *path2 = makeTempPathW(@"legacy");
    NSError *err2 = nil;
    TTIOSpectralDataset *ds2 = makeWritableDatasetForPath(path2, &err2);
    TTIOReferenceImport *ri2 = [[TTIOReferenceImport alloc]
        initWithUri:@"legacy-v1"
        chromosomes:@[@"chr1"]
          sequences:@[[@"ACGT" dataUsingEncoding:NSUTF8StringEncoding]]];
    PASS([ri2 writeToDataset:ds2 overwrite:NO error:&err2],
         "progress: legacy writeToDataset:overwrite:error: still works");

    [ds closeFile];
    [ds2 closeFile];
    unlink([path fileSystemRepresentation]);
    unlink([path2 fileSystemRepresentation]);
}

void testReferenceImportWriteToDataset(void);
void testReferenceImportWriteToDataset(void)
{
    testWriteToDatasetRoundTripsThroughReferences();
    testWriteToDatasetRejectsDuplicateUriWithoutOverwrite();
    testWriteToDatasetOverwriteReplacesExistingReference();
    testWriteToDatasetProgressFires();
}
