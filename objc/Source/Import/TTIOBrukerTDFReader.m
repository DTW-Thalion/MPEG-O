/*
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOBrukerTDFReader.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <sqlite3.h>

@interface TTIOBrukerTDFMetadata ()
- (instancetype)initWithFrameCount:(NSInteger)frameCount
                      ms1FrameCount:(NSInteger)ms1
                      ms2FrameCount:(NSInteger)ms2
                   retentionTimeMin:(double)rtMin
                   retentionTimeMax:(double)rtMax
                   instrumentVendor:(NSString *)vendor
                    instrumentModel:(NSString *)model
                acquisitionSoftware:(NSString *)software
                          properties:(NSDictionary *)properties
                     globalMetadata:(NSDictionary *)globalMetadata;
@end

@implementation TTIOBrukerTDFMetadata

- (instancetype)initWithFrameCount:(NSInteger)frameCount
                      ms1FrameCount:(NSInteger)ms1
                      ms2FrameCount:(NSInteger)ms2
                   retentionTimeMin:(double)rtMin
                   retentionTimeMax:(double)rtMax
                   instrumentVendor:(NSString *)vendor
                    instrumentModel:(NSString *)model
                acquisitionSoftware:(NSString *)software
                          properties:(NSDictionary *)properties
                     globalMetadata:(NSDictionary *)globalMetadata
{
    self = [super init];
    if (self) {
        _frameCount = frameCount;
        _ms1FrameCount = ms1;
        _ms2FrameCount = ms2;
        _retentionTimeMin = rtMin;
        _retentionTimeMax = rtMax;
        _instrumentVendor = [vendor copy];
        _instrumentModel = [model copy];
        _acquisitionSoftware = [software copy];
        _properties = [properties copy];
        _globalMetadata = [globalMetadata copy];
    }
    return self;
}

@end

// ─────────────────────────────────────────────────────────────────────────

static NSString *btdfLocateTdf(NSString *dDir, NSError **error)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dDir isDirectory:&isDir] || !isDir) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound,
            @"No analysis.tdf found under %@ — is this a Bruker .d directory?",
            dDir);
        return nil;
    }
    NSString *direct = [dDir stringByAppendingPathComponent:@"analysis.tdf"];
    if ([fm fileExistsAtPath:direct]) return direct;

    // Try one level down (some tools nest .d inside a parent dir).
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dDir error:NULL];
    for (NSString *e in entries) {
        NSString *child = [dDir stringByAppendingPathComponent:e];
        [fm fileExistsAtPath:child isDirectory:&isDir];
        if (!isDir) continue;
        NSString *nested = [child stringByAppendingPathComponent:@"analysis.tdf"];
        if ([fm fileExistsAtPath:nested]) return nested;
    }
    if (error) *error = TTIOMakeError(TTIOErrorFileNotFound,
        @"No analysis.tdf found under %@ — is this a Bruker .d directory?",
        dDir);
    return nil;
}

static NSString *btdfPick(NSDictionary *d, NSArray<NSString *> *keys)
{
    for (NSString *k in keys) {
        NSString *v = d[k];
        if (v.length > 0) return v;
    }
    return @"";
}

@implementation TTIOBrukerTDFReader

+ (nullable TTIOBrukerTDFMetadata *)readMetadataAtPath:(NSString *)dDir
                                                   error:(NSError **)error
{
    NSString *tdf = btdfLocateTdf(dDir, error);
    if (!tdf) return nil;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(tdf.fileSystemRepresentation, &db,
                         SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"cannot open analysis.tdf: %@", tdf);
        if (db) sqlite3_close(db);
        return nil;
    }

    NSInteger frameCount = 0, ms1 = 0, ms2 = 0;
    double rtMin = 0.0, rtMax = 0.0;
    NSMutableDictionary *globalMd = [NSMutableDictionary dictionary];
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];

    sqlite3_stmt *stmt = NULL;
    const char *q1 = "SELECT COUNT(*) FROM Frames";
    if (sqlite3_prepare_v2(db, q1, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            frameCount = sqlite3_column_int(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    const char *q2 = "SELECT COUNT(*) FROM Frames WHERE MsMsType = 0";
    if (sqlite3_prepare_v2(db, q2, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) ms1 = sqlite3_column_int(stmt, 0);
        sqlite3_finalize(stmt);
    }
    const char *q3 = "SELECT COUNT(*) FROM Frames WHERE MsMsType != 0";
    if (sqlite3_prepare_v2(db, q3, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) ms2 = sqlite3_column_int(stmt, 0);
        sqlite3_finalize(stmt);
    }
    const char *q4 = "SELECT MIN(Time), MAX(Time) FROM Frames";
    if (sqlite3_prepare_v2(db, q4, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            rtMin = sqlite3_column_double(stmt, 0);
            rtMax = sqlite3_column_double(stmt, 1);
        }
        sqlite3_finalize(stmt);
    }

    const char *kv_queries[2] = {
        "SELECT Key, Value FROM GlobalMetadata",
        "SELECT Key, Value FROM Properties",
    };
    NSMutableDictionary *kv_targets[2] = { globalMd, properties };
    for (int i = 0; i < 2; i++) {
        if (sqlite3_prepare_v2(db, kv_queries[i], -1, &stmt, NULL) != SQLITE_OK) {
            // Table missing — silent fallback.
            continue;
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *k = sqlite3_column_text(stmt, 0);
            const unsigned char *v = sqlite3_column_text(stmt, 1);
            if (!k) continue;
            NSString *ks = [NSString stringWithUTF8String:(const char *)k];
            NSString *vs = v ? [NSString stringWithUTF8String:(const char *)v] : @"";
            if (ks) kv_targets[i][ks] = vs ?: @"";
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);

    NSString *vendor = btdfPick(globalMd, @[@"InstrumentVendor", @"Vendor"]);
    if (vendor.length == 0) vendor = @"Bruker";
    NSString *model = btdfPick(globalMd, @[@"InstrumentName", @"Model",
                                              @"MaldiApplicationType"]);
    NSString *software = btdfPick(globalMd, @[@"AcquisitionSoftware",
                                                 @"OperatingSystem"]);

    return [[TTIOBrukerTDFMetadata alloc]
                initWithFrameCount:frameCount
                     ms1FrameCount:ms1
                     ms2FrameCount:ms2
                  retentionTimeMin:rtMin
                  retentionTimeMax:rtMax
                  instrumentVendor:vendor
                   instrumentModel:model
               acquisitionSoftware:software
                         properties:properties
                    globalMetadata:globalMd];
}

static NSString *btdfResolvePython(void)
{
    NSString *env = [[NSProcessInfo processInfo] environment][@"TTIO_PYTHON"];
    if (env.length > 0) return env;
    NSString *path = [[NSProcessInfo processInfo] environment][@"PATH"];
    if (!path) return nil;
    NSArray *parts = [path componentsSeparatedByString:@":"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *candidate in @[@"python3", @"python"]) {
        for (NSString *dir in parts) {
            NSString *full = [dir stringByAppendingPathComponent:candidate];
            if ([fm isExecutableFileAtPath:full]) return full;
        }
    }
    return nil;
}

+ (BOOL)importFromPath:(NSString *)dDir
             toOutput:(NSString *)output
                error:(NSError **)error
{
    // Metadata read catches malformed input before the subprocess spawn.
    NSError *mdErr = nil;
    TTIOBrukerTDFMetadata *md = [self readMetadataAtPath:dDir error:&mdErr];
    if (!md) {
        if (error) *error = mdErr;
        return NO;
    }

    NSString *python = btdfResolvePython();
    if (!python) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"No Python interpreter found — set TTIO_PYTHON or put "
            @"python3 on PATH to use the Bruker TDF binary helper.");
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = python;
    task.arguments = @[
        @"-m", @"ttio.importers.bruker_tdf_cli",
        @"--input", dDir,
        @"--output", output,
    ];
    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = outPipe;
    @try {
        [task launch];
    } @catch (NSException *exc) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"failed to launch Python helper: %@ (%@)",
            python, exc.reason);
        return NO;
    }
    [task waitUntilExit];
    NSData *out = [[outPipe fileHandleForReading] readDataToEndOfFile];
    int exit = task.terminationStatus;
    if (exit != 0) {
        NSString *msg = [[NSString alloc] initWithData:out
                                                encoding:NSUTF8StringEncoding];
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"Python bruker_tdf helper exited %d: %@",
            exit, [msg stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"(no output)");
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isReadableFileAtPath:output]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"bruker_tdf helper reported success but produced no "
            @"output: %@", output);
        return NO;
    }
    return YES;
}

@end
