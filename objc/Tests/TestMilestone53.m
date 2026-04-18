/*
 * TestMilestone53 — ObjC MPGOBrukerTDFReader (metadata side).
 *
 * Binary round-trip via NSTask is exercised by
 * python/tests/test_bruker_tdf.py::test_real_tdf_round_trip when a
 * real `.d` fixture is available (MPGO_BRUKER_TDF_FIXTURE env var).
 * This suite covers the SQLite metadata path with a synthetic
 * fixture.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <sqlite3.h>
#import <unistd.h>

#import "Import/MPGOBrukerTDFReader.h"

static NSString *m53TempDir(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m53_%d_%@.d",
            (int)getpid(), suffix];
}

static void rm_rf53(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void writeSyntheticTdf(NSString *dDir, NSInteger frameCount,
                                NSInteger ms1Count, NSString *vendor,
                                NSString *model)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:dDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *tdf = [dDir stringByAppendingPathComponent:@"analysis.tdf"];
    sqlite3 *db = NULL;
    sqlite3_open_v2(tdf.fileSystemRepresentation, &db,
                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    const char *sql =
        "CREATE TABLE Frames ("
        "  Id INTEGER PRIMARY KEY, Time REAL NOT NULL, "
        "  MsMsType INTEGER NOT NULL);"
        "CREATE TABLE GlobalMetadata (Key TEXT PRIMARY KEY, Value TEXT);"
        "CREATE TABLE Properties (Key TEXT PRIMARY KEY, Value TEXT);";
    sqlite3_exec(db, sql, NULL, NULL, NULL);
    for (NSInteger i = 0; i < frameCount; i++) {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "INSERT INTO Frames VALUES (%ld, %f, %d);",
                 (long)(i + 1), 0.5 * (i + 1), i < ms1Count ? 0 : 9);
        sqlite3_exec(db, buf, NULL, NULL, NULL);
    }
    sqlite3_stmt *stmt = NULL;
    const char *ins = "INSERT INTO GlobalMetadata (Key, Value) VALUES (?, ?)";
    NSArray *gm = @[@[@"InstrumentVendor", vendor],
                     @[@"InstrumentName", model],
                     @[@"AcquisitionSoftware", @"timsControl 4.0"]];
    for (NSArray *kv in gm) {
        sqlite3_prepare_v2(db, ins, -1, &stmt, NULL);
        sqlite3_bind_text(stmt, 1, [kv[0] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [kv[1] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
    const char *insProp = "INSERT INTO Properties (Key, Value) VALUES (?, ?)";
    NSArray *props = @[@[@"MotorZ1", @"-0.5"],
                        @[@"BeamSplitterConfig", @"NONE"]];
    for (NSArray *kv in props) {
        sqlite3_prepare_v2(db, insProp, -1, &stmt, NULL);
        sqlite3_bind_text(stmt, 1, [kv[0] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [kv[1] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

void testMilestone53(void)
{
    NSString *path = m53TempDir(@"synth");
    rm_rf53(path);
    writeSyntheticTdf(path, 5, 3, @"Bruker Daltonics", @"timsTOF SCP");

    NSError *err = nil;
    MPGOBrukerTDFMetadata *md =
        [MPGOBrukerTDFReader readMetadataAtPath:path error:&err];
    PASS(md != nil, "M53: readMetadataAtPath returns non-nil");
    PASS(md.frameCount == 5, "M53: frameCount is 5");
    PASS(md.ms1FrameCount == 3, "M53: ms1FrameCount is 3");
    PASS(md.ms2FrameCount == 2, "M53: ms2FrameCount is 2");
    PASS([md.instrumentVendor isEqualToString:@"Bruker Daltonics"],
         "M53: instrumentVendor round-trips");
    PASS([md.instrumentModel isEqualToString:@"timsTOF SCP"],
         "M53: instrumentModel round-trips");
    PASS([md.acquisitionSoftware isEqualToString:@"timsControl 4.0"],
         "M53: acquisitionSoftware round-trips");
    PASS(md.retentionTimeMax > md.retentionTimeMin,
         "M53: retentionTime range populated");
    PASS([md.properties[@"BeamSplitterConfig"] isEqualToString:@"NONE"],
         "M53: property round-trips");
    rm_rf53(path);

    // Missing directory → clean error.
    NSString *missing = m53TempDir(@"does-not-exist");
    err = nil;
    MPGOBrukerTDFMetadata *md2 =
        [MPGOBrukerTDFReader readMetadataAtPath:missing error:&err];
    PASS(md2 == nil && err != nil,
         "M53: readMetadataAtPath populates NSError on missing dir");

    // No GlobalMetadata → vendor defaults to "Bruker".
    NSString *minPath = m53TempDir(@"minimal");
    rm_rf53(minPath);
    [[NSFileManager defaultManager] createDirectoryAtPath:minPath
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *tdf = [minPath stringByAppendingPathComponent:@"analysis.tdf"];
    sqlite3 *db = NULL;
    sqlite3_open_v2(tdf.fileSystemRepresentation, &db,
                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    sqlite3_exec(db,
        "CREATE TABLE Frames (Id INTEGER PRIMARY KEY, Time REAL, MsMsType INTEGER);"
        "INSERT INTO Frames VALUES (1, 0.5, 0);",
        NULL, NULL, NULL);
    sqlite3_close(db);
    err = nil;
    MPGOBrukerTDFMetadata *md3 =
        [MPGOBrukerTDFReader readMetadataAtPath:minPath error:&err];
    PASS(md3 != nil && [md3.instrumentVendor isEqualToString:@"Bruker"],
         "M53: vendor defaults to 'Bruker' when GlobalMetadata missing");
    rm_rf53(minPath);
}
