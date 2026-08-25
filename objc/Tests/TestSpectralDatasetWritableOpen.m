// TestSpectralDatasetWritableOpen.m — M100
// Public writable dataset open:
// +[TTIOSpectralDataset readFromFilePath:writable:error:].
// Mirror of Python SpectralDataset.open(path, writable=True) ("r+")
// and Java SpectralDataset.open(pathOrUrl, writable). A dataset
// opened writable feeds
// -[TTIOReferenceImport writeToDataset:overwrite:error:], which
// needs an open ReadWrite provider behind -[TTIOSpectralDataset
// provider].
//
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOReferenceImport.h"
#include <unistd.h>

static NSString *makeTempPathWO(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_wopen_%d_%@.tio",
                      (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static BOOL seedMinimal(NSString *path, NSError **error)
{
    return [TTIOSpectralDataset writeMinimalToPath:path
                                             title:@"m100-seed"
                                isaInvestigationId:@"M100SEED"
                                            msRuns:@{}
                                   identifications:nil
                                   quantifications:nil
                                 provenanceRecords:nil
                                             error:error];
}

/* writable:YES returns a fully-read dataset whose provider accepts
 * writeToDataset:, and the write survives a plain read-only reopen. */
static void testWritableOpenRoundTripsReferences(void)
{
    NSString *path = makeTempPathWO(@"round_trip");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    PASS(seedMinimal(path, &err) && err == nil,
         "M100: seed minimal .tio written");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path writable:YES error:&err];
    PASS(ds != nil && err == nil, "M100: writable open returns a dataset");
    PASS([ds.title isEqualToString:@"m100-seed"],
         "M100: writable open runs the full reader (title read back)");
    PASS(ds.provider != nil && [ds.provider isOpen],
         "M100: writable open surfaces an open provider");

    NSData *chr1 = [@"ACGTACGTACGT" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *chr2 = [@"TTTTAAAACCCC" dataUsingEncoding:NSASCIIStringEncoding];
    TTIOReferenceImport *ri =
        [[TTIOReferenceImport alloc] initWithUri:@"m100-ref-v1"
                                     chromosomes:@[@"chr1", @"chr2"]
                                       sequences:@[chr1, chr2]];
    PASS([ri writeToDataset:ds error:&err] && err == nil,
         "M100: writeToDataset succeeds on a writable-opened dataset");
    [ds closeFile];

    NSError *rerr = nil;
    TTIOSpectralDataset *ro =
        [TTIOSpectralDataset readFromFilePath:path error:&rerr];
    PASS(ro != nil, "M100: read-only reopen succeeds");
    TTIOReferenceImport *out = ro.references[@"m100-ref-v1"];
    PASS(out != nil, "M100: embedded reference present after reopen");
    PASS([[out chromosomeNamed:@"chr1"] isEqualToData:chr1]
         && [[out chromosomeNamed:@"chr2"] isEqualToData:chr2],
         "M100: sequences round-trip byte-equal");
    [ro closeFile];
    unlink([path fileSystemRepresentation]);
}

/* writable:NO is the control: same entry point, the write must fail
 * and leave nothing on disk — the writable flag alone selects
 * ReadWrite mode. */
static void testReadOnlyOpenRejectsWrite(void)
{
    NSString *path = makeTempPathWO(@"ro_control");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    PASS(seedMinimal(path, &err), "M100: seed minimal .tio written");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path writable:NO error:&err];
    PASS(ds != nil, "M100: writable:NO open returns a dataset");

    TTIOReferenceImport *ri =
        [[TTIOReferenceImport alloc]
            initWithUri:@"m100-ro-v1"
            chromosomes:@[@"chr1"]
              sequences:@[[@"ACGT" dataUsingEncoding:NSASCIIStringEncoding]]];
    NSError *werr = nil;
    BOOL wrote = [ri writeToDataset:ds error:&werr];
    PASS(!wrote,
         "M100: writeToDataset fails on a read-only-opened dataset");
    [ds closeFile];

    NSError *rerr = nil;
    TTIOSpectralDataset *ro =
        [TTIOSpectralDataset readFromFilePath:path error:&rerr];
    PASS(ro != nil && ro.references[@"m100-ro-v1"] == nil,
         "M100: failed write left no reference on disk");
    [ro closeFile];
    unlink([path fileSystemRepresentation]);
}

/* Python "r+" on a missing file raises; the ObjC mirror returns
 * nil with an error rather than creating the file. */
static void testWritableOpenMissingFileErrors(void)
{
    NSString *path = makeTempPathWO(@"missing");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path writable:YES error:&err];
    PASS(ds == nil && err != nil,
         "M100: writable open of a missing file fails with an error");
    PASS(![[NSFileManager defaultManager] fileExistsAtPath:path],
         "M100: writable open did not create the missing file");
}

void testSpectralDatasetWritableOpen(void);
void testSpectralDatasetWritableOpen(void)
{
    testWritableOpenRoundTripsReferences();
    testReadOnlyOpenRejectsWrite();
    testWritableOpenMissingFileErrors();
}
