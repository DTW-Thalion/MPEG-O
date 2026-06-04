/*
 * TestBrukerReaderDataset — OT4: Bruker readDataset write-through draft.
 *
 * OT4 adds +readDatasetFromPath:error: to TTIOBrukerTDFReader, returning a
 * TTIOImportedDataset whose writeDelegate runs the Python subprocess only at
 * -writeToPath: time. The draft itself is built WITHOUT spawning the
 * subprocess; it performs the SAME up-front SQLite metadata validation that
 * +importFromPath:toOutput:error: does (so it fails fast identically).
 *
 * Reflection / smoke only — no real Bruker binary fixture required. The
 * subprocess is never launched here (we never call -writeToPath:). Mirrors
 * the guarded Java Bruker readDataset test.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <sqlite3.h>
#import <unistd.h>

#import "Import/TTIOBrukerTDFReader.h"
#import "Import/TTIOImportedDataset.h"

static NSString *otb4TempDir(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_otb4_%d_%@.d",
            (int)getpid(), suffix];
}

static void otb4_rm_rf(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

/* Minimal synthetic Bruker .d directory: just enough SQLite metadata to pass
 * the up-front validation in +readDatasetFromPath:. No binary blob — the
 * subprocess is never run in this suite. */
static void otb4_writeSyntheticTdf(NSString *dDir)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:dDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *tdf = [dDir stringByAppendingPathComponent:@"analysis.tdf"];
    sqlite3 *db = NULL;
    sqlite3_open_v2(tdf.fileSystemRepresentation, &db,
                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    sqlite3_exec(db,
        "CREATE TABLE Frames (Id INTEGER PRIMARY KEY, Time REAL, MsMsType INTEGER);"
        "INSERT INTO Frames VALUES (1, 0.5, 0);",
        NULL, NULL, NULL);
    sqlite3_close(db);
}

void testBrukerReaderDataset(void)
{
    @autoreleasepool {
        // (1) Surface: the selector exists.
        PASS([TTIOBrukerTDFReader
                 respondsToSelector:@selector(readDatasetFromPath:error:)],
             "OT4: +readDatasetFromPath:error: selector exists");

        // (2) Valid synthetic .d: returns a TTIOImportedDataset whose
        //     writeDelegate is set. The subprocess is NOT run here — only
        //     the up-front metadata validation runs at readDataset time.
        NSString *path = otb4TempDir(@"synth");
        otb4_rm_rf(path);
        otb4_writeSyntheticTdf(path);

        NSError *err = nil;
        TTIOImportedDataset *ds =
            [TTIOBrukerTDFReader readDatasetFromPath:path error:&err];
        PASS([ds isKindOfClass:[TTIOImportedDataset class]],
             "OT4: readDatasetFromPath returns a TTIOImportedDataset draft");
        PASS(ds.writeDelegate != nil,
             "OT4: draft carries a write-through delegate (subprocess deferred)");
        otb4_rm_rf(path);

        // (3) Bogus path: the SAME up-front metadata validation that
        //     +importFromPath: performs fails fast → nil + NSError, with no
        //     subprocess spawned.
        NSString *missing = otb4TempDir(@"does-not-exist");
        otb4_rm_rf(missing);
        err = nil;
        TTIOImportedDataset *bad =
            [TTIOBrukerTDFReader readDatasetFromPath:missing error:&err];
        PASS(bad == nil && err != nil,
             "OT4: readDatasetFromPath fails fast (nil+error) on a bogus path");
    }
}
