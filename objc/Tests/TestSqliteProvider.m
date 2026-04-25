// TestSqliteProvider.m — Milestone 41: SQLite storage provider tests.
//
// Mirrors the Python and Java SqliteProvider test suites.
// All assertions use the Testing.h PASS macro (rfm style).

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOSqliteProvider.h"
#import "Providers/TTIOCompoundField.h"
#import "ValueClasses/TTIOEnums.h"
#import <unistd.h>
#import <math.h>

// ── Path helpers ─────────────────────────────────────────────

static NSString *sqliteTmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_sqlite_%d_%@.tio.sqlite",
            (int)getpid(), suffix];
}

// ── Byte helpers (little-endian pack / unpack on x86-64) ─────

static NSData *packFloat64(const double *vals, NSUInteger n)
{
    return [NSData dataWithBytes:vals length:n * sizeof(double)];
}

static NSData *packFloat32(const float *vals, NSUInteger n)
{
    return [NSData dataWithBytes:vals length:n * sizeof(float)];
}

static NSData *packInt32(const int32_t *vals, NSUInteger n)
{
    return [NSData dataWithBytes:vals length:n * sizeof(int32_t)];
}

static NSData *packInt64(const int64_t *vals, NSUInteger n)
{
    return [NSData dataWithBytes:vals length:n * sizeof(int64_t)];
}

static NSData *packUInt32(const uint32_t *vals, NSUInteger n)
{
    return [NSData dataWithBytes:vals length:n * sizeof(uint32_t)];
}

/** Complex128: interleaved little-endian doubles (re0, im0, re1, im1, ...) */
static NSData *packComplex128(const double *vals, NSUInteger pairs)
{
    return [NSData dataWithBytes:vals length:pairs * 2 * sizeof(double)];
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 1: Provider registration
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteRegistration(void)
{
    NSArray *known = [[TTIOProviderRegistry sharedRegistry] knownProviderNames];
    PASS([known containsObject:@"sqlite"],
         "Sqlite: registry knows sqlite");
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 2: Open / create / close lifecycle
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteLifecycle(void)
{
    NSString *path = sqliteTmpPath(@"lifecycle");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];
    PASS(p != nil, "Sqlite lifecycle: open CREATE");
    PASS([p isOpen], "Sqlite lifecycle: isOpen after CREATE");

    [p close];
    PASS(![p isOpen], "Sqlite lifecycle: isOpen false after close");

    // Re-open read-only
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    PASS(p != nil, "Sqlite lifecycle: open READ");
    [p close];

    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 3: Group hierarchy + child listing
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteGroupHierarchy(void)
{
    NSString *path = sqliteTmpPath(@"groups");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];
    PASS(p != nil, "Sqlite groups: open");

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    PASS(root != nil, "Sqlite groups: rootGroup");

    id<TTIOStorageGroup> samples = [root createGroupNamed:@"samples" error:&err];
    PASS(samples != nil, "Sqlite groups: createGroup samples");

    id<TTIOStorageGroup> run1 = [samples createGroupNamed:@"run1" error:&err];
    PASS(run1 != nil, "Sqlite groups: createGroup run1");

    id<TTIOStorageGroup> run2 = [samples createGroupNamed:@"run2" error:&err];
    PASS(run2 != nil, "Sqlite groups: createGroup run2");

    PASS([root hasChildNamed:@"samples"], "Sqlite groups: hasChild samples");
    PASS([samples hasChildNamed:@"run1"], "Sqlite groups: hasChild run1");
    PASS([samples hasChildNamed:@"run2"], "Sqlite groups: hasChild run2");
    PASS(![samples hasChildNamed:@"run3"], "Sqlite groups: !hasChild run3");

    NSArray *childNames = [samples childNames];
    PASS([childNames containsObject:@"run1"], "Sqlite groups: childNames run1");
    PASS([childNames containsObject:@"run2"], "Sqlite groups: childNames run2");
    PASS(childNames.count == 2, "Sqlite groups: childNames count 2");

    [p close];

    // Reopen and verify hierarchy persisted
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];
    samples = [root openGroupNamed:@"samples" error:&err];
    PASS(samples != nil, "Sqlite groups: re-open samples");
    run1 = [samples openGroupNamed:@"run1" error:&err];
    PASS(run1 != nil, "Sqlite groups: re-open run1");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 4: Primitive 1-D dataset round-trip
// ────────────────────────────────────────────────────────────────────────────

static void testSqlitePrimitive1D(void)
{
    NSString *path = sqliteTmpPath(@"prim1d");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];

    double vals[] = {1.0, 2.5, 3.14159, -0.001, 1e10};
    NSUInteger n = 5;
    id<TTIOStorageDataset> ds =
        [root createDatasetNamed:@"intensities"
                        precision:TTIOPrecisionFloat64
                           length:n
                        chunkSize:0
                      compression:TTIOCompressionNone
                 compressionLevel:0
                            error:&err];
    PASS(ds != nil, "Sqlite prim1D: createDataset");
    PASS(ds.length == 5, "Sqlite prim1D: length == 5");
    PASS([[ds shape] count] == 1, "Sqlite prim1D: shape rank == 1");
    PASS([[[ds shape] firstObject] unsignedIntegerValue] == 5,
         "Sqlite prim1D: shape[0] == 5");

    NSData *blob = packFloat64(vals, n);
    PASS([ds writeAll:blob error:&err], "Sqlite prim1D: writeAll");

    [p close];

    // Re-open read-only and verify
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"intensities" error:&err];
    PASS(ds != nil, "Sqlite prim1D: re-open dataset");

    NSData *back = [ds readAll:&err];
    PASS(back != nil, "Sqlite prim1D: readAll not nil");
    PASS(back.length == n * sizeof(double), "Sqlite prim1D: readAll length correct");

    const double *got = (const double *)back.bytes;
    PASS(got[0] == vals[0], "Sqlite prim1D: vals[0] round-trip");
    PASS(got[2] == vals[2], "Sqlite prim1D: vals[2] round-trip");
    PASS(got[4] == vals[4], "Sqlite prim1D: vals[4] round-trip");

    // Slice read
    NSData *slice = [ds readSliceAtOffset:1 count:2 error:&err];
    PASS(slice != nil, "Sqlite prim1D: slice not nil");
    PASS(slice.length == 2 * sizeof(double), "Sqlite prim1D: slice length");
    const double *sv = (const double *)slice.bytes;
    PASS(sv[0] == vals[1], "Sqlite prim1D: slice[0] == vals[1]");
    PASS(sv[1] == vals[2], "Sqlite prim1D: slice[1] == vals[2]");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 5: Primitive N-D dataset round-trip (2-D)
// ────────────────────────────────────────────────────────────────────────────

static void testSqlitePrimitiveND(void)
{
    NSString *path = sqliteTmpPath(@"primnd");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];

    // 3×4 float32 matrix
    float mat[12];
    for (int i = 0; i < 12; i++) mat[i] = (float)i * 0.5f;

    NSArray *shape = @[@3, @4];
    id<TTIOStorageDataset> ds =
        [root createDatasetNDNamed:@"matrix"
                          precision:TTIOPrecisionFloat32
                              shape:shape
                             chunks:nil
                        compression:TTIOCompressionNone
                   compressionLevel:0
                              error:&err];
    PASS(ds != nil, "Sqlite ND: createDatasetND");
    PASS(ds.shape.count == 2, "Sqlite ND: shape rank == 2");
    PASS([ds.shape[0] unsignedIntegerValue] == 3, "Sqlite ND: shape[0] == 3");
    PASS([ds.shape[1] unsignedIntegerValue] == 4, "Sqlite ND: shape[1] == 4");

    NSData *blob = packFloat32(mat, 12);
    PASS([ds writeAll:blob error:&err], "Sqlite ND: writeAll");

    [p close];

    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"matrix" error:&err];
    PASS(ds != nil, "Sqlite ND: re-open dataset");
    PASS(ds.shape.count == 2, "Sqlite ND: shape rank persisted");

    NSData *back = [ds readAll:&err];
    PASS(back.length == 12 * sizeof(float), "Sqlite ND: readAll length");
    const float *gm = (const float *)back.bytes;
    PASS(gm[5] == mat[5], "Sqlite ND: mat[5] round-trip");
    PASS(gm[11] == mat[11], "Sqlite ND: mat[11] round-trip");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 6: Compound dataset round-trip
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteCompound(void)
{
    NSString *path = sqliteTmpPath(@"compound");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];

    NSArray *fields = @[
        [TTIOCompoundField fieldWithName:@"run_name"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"spectrum_index"
                                    kind:TTIOCompoundFieldKindUInt32],
        [TTIOCompoundField fieldWithName:@"confidence_score"
                                    kind:TTIOCompoundFieldKindFloat64],
    ];
    NSArray *rows = @[
        @{@"run_name": @"run_A",
          @"spectrum_index": @(0),
          @"confidence_score": @(0.95)},
        @{@"run_name": @"run_B",
          @"spectrum_index": @(3),
          @"confidence_score": @(0.72)},
        @{@"run_name": @"run_C",
          @"spectrum_index": @(7),
          @"confidence_score": @(0.88)},
    ];

    id<TTIOStorageDataset> ds =
        [root createCompoundDatasetNamed:@"hits"
                                    fields:fields
                                     count:rows.count
                                     error:&err];
    PASS(ds != nil, "Sqlite compound: createCompoundDataset");
    PASS(ds.compoundFields.count == 3, "Sqlite compound: compoundFields count");
    PASS([ds writeAll:rows error:&err], "Sqlite compound: writeAll");

    [p close];

    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"hits" error:&err];
    PASS(ds != nil, "Sqlite compound: re-open dataset");
    PASS(ds.compoundFields != nil, "Sqlite compound: compoundFields non-nil");
    PASS(ds.compoundFields.count == 3, "Sqlite compound: compoundFields count persisted");

    NSArray *back = [ds readAll:&err];
    PASS([back isKindOfClass:[NSArray class]], "Sqlite compound: readAll is NSArray");
    PASS(back.count == 3, "Sqlite compound: row count == 3");

    NSDictionary *r0 = back[0];
    PASS([r0[@"run_name"] isEqualToString:@"run_A"],
         "Sqlite compound: row0 run_name");
    PASS([r0[@"spectrum_index"] intValue] == 0,
         "Sqlite compound: row0 spectrum_index");
    PASS(fabs([r0[@"confidence_score"] doubleValue] - 0.95) < 1e-10,
         "Sqlite compound: row0 confidence_score");

    NSDictionary *r2 = back[2];
    PASS([r2[@"run_name"] isEqualToString:@"run_C"],
         "Sqlite compound: row2 run_name");

    // Slice
    NSArray *slice = [ds readSliceAtOffset:1 count:2 error:&err];
    PASS(slice.count == 2, "Sqlite compound: slice count 2");
    PASS([slice[0][@"run_name"] isEqualToString:@"run_B"],
         "Sqlite compound: slice[0] run_name == run_B");

    // Fields round-trip
    PASS([[ds.compoundFields[0] name] isEqualToString:@"run_name"],
         "Sqlite compound: field[0] name");
    PASS([ds.compoundFields[0] kind] == TTIOCompoundFieldKindVLString,
         "Sqlite compound: field[0] kind VLString");
    PASS([[ds.compoundFields[1] name] isEqualToString:@"spectrum_index"],
         "Sqlite compound: field[1] name");
    PASS([ds.compoundFields[1] kind] == TTIOCompoundFieldKindUInt32,
         "Sqlite compound: field[1] kind UInt32");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 7: Group attributes (string / int / float)
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteGroupAttributes(void)
{
    NSString *path = sqliteTmpPath(@"grpattr");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];

    PASS([root setAttributeValue:@"cross-lang test"
                         forName:@"title" error:&err],
         "Sqlite grpattr: set string");
    PASS([root setAttributeValue:@(42)
                         forName:@"version" error:&err],
         "Sqlite grpattr: set int");
    PASS([root setAttributeValue:@(3.14)
                         forName:@"pi" error:&err],
         "Sqlite grpattr: set float");

    PASS([root hasAttributeNamed:@"title"],  "Sqlite grpattr: has title");
    PASS([root hasAttributeNamed:@"version"], "Sqlite grpattr: has version");
    PASS(![root hasAttributeNamed:@"missing"], "Sqlite grpattr: !has missing");

    id tv = [root attributeValueForName:@"title" error:&err];
    PASS([tv isKindOfClass:[NSString class]], "Sqlite grpattr: title is NSString");
    PASS([(NSString *)tv isEqualToString:@"cross-lang test"],
         "Sqlite grpattr: title value");

    id vv = [root attributeValueForName:@"version" error:&err];
    PASS([vv isKindOfClass:[NSNumber class]], "Sqlite grpattr: version is NSNumber");
    PASS([(NSNumber *)vv longLongValue] == 42, "Sqlite grpattr: version value");

    id pv = [root attributeValueForName:@"pi" error:&err];
    PASS([pv isKindOfClass:[NSNumber class]], "Sqlite grpattr: pi is NSNumber");
    PASS(fabs([(NSNumber *)pv doubleValue] - 3.14) < 1e-10,
         "Sqlite grpattr: pi value");

    NSArray *names = [root attributeNames];
    PASS([names containsObject:@"title"],   "Sqlite grpattr: attributeNames has title");
    PASS([names containsObject:@"version"], "Sqlite grpattr: attributeNames has version");
    PASS([names containsObject:@"pi"],      "Sqlite grpattr: attributeNames has pi");

    [p close];

    // Reopen and verify persistence
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];

    tv = [root attributeValueForName:@"title" error:&err];
    PASS([(NSString *)tv isEqualToString:@"cross-lang test"],
         "Sqlite grpattr: persisted title");
    vv = [root attributeValueForName:@"version" error:&err];
    PASS([(NSNumber *)vv longLongValue] == 42,
         "Sqlite grpattr: persisted version");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 8: Dataset attributes
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteDatasetAttributes(void)
{
    NSString *path = sqliteTmpPath(@"dsattr");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    id<TTIOStorageDataset> ds =
        [root createDatasetNamed:@"mz"
                        precision:TTIOPrecisionFloat64
                           length:3
                        chunkSize:0
                      compression:TTIOCompressionNone
                 compressionLevel:0
                            error:&err];
    PASS(ds != nil, "Sqlite dsattr: createDataset");

    PASS([ds setAttributeValue:@"m/z array"
                       forName:@"label" error:&err],
         "Sqlite dsattr: set string label");
    PASS([ds setAttributeValue:@(100)
                       forName:@"scan_num" error:&err],
         "Sqlite dsattr: set int");
    PASS([ds setAttributeValue:@(0.001)
                       forName:@"tolerance" error:&err],
         "Sqlite dsattr: set float");

    PASS([ds hasAttributeNamed:@"label"],    "Sqlite dsattr: has label");
    PASS([ds hasAttributeNamed:@"scan_num"], "Sqlite dsattr: has scan_num");

    id lv = [ds attributeValueForName:@"label" error:&err];
    PASS([(NSString *)lv isEqualToString:@"m/z array"],
         "Sqlite dsattr: label value");
    id sv = [ds attributeValueForName:@"scan_num" error:&err];
    PASS([(NSNumber *)sv longLongValue] == 100,
         "Sqlite dsattr: scan_num value");
    id tv = [ds attributeValueForName:@"tolerance" error:&err];
    PASS(fabs([(NSNumber *)tv doubleValue] - 0.001) < 1e-12,
         "Sqlite dsattr: tolerance value");

    [p close];

    // Reopen and verify
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"mz" error:&err];
    PASS(ds != nil, "Sqlite dsattr: re-open dataset");
    lv = [ds attributeValueForName:@"label" error:&err];
    PASS([(NSString *)lv isEqualToString:@"m/z array"],
         "Sqlite dsattr: persisted label");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 9: All 6 precisions round-trip
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteAllPrecisions(void)
{
    NSString *path = sqliteTmpPath(@"precisions");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];
    PASS(p != nil, "Sqlite precisions: open");

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];

    // FLOAT32
    {
        float v[] = {1.5f, -2.5f, 3.14f};
        id<TTIOStorageDataset> ds =
            [root createDatasetNamed:@"f32" precision:TTIOPrecisionFloat32
                              length:3 chunkSize:0
                         compression:TTIOCompressionNone compressionLevel:0
                               error:&err];
        [ds writeAll:packFloat32(v, 3) error:&err];
    }
    // FLOAT64
    {
        double v[] = {1.5, -2.5, 3.14159265358979};
        id<TTIOStorageDataset> ds =
            [root createDatasetNamed:@"f64" precision:TTIOPrecisionFloat64
                              length:3 chunkSize:0
                         compression:TTIOCompressionNone compressionLevel:0
                               error:&err];
        [ds writeAll:packFloat64(v, 3) error:&err];
    }
    // INT32
    {
        int32_t v[] = {-1000000, 0, 2147483647};
        id<TTIOStorageDataset> ds =
            [root createDatasetNamed:@"i32" precision:TTIOPrecisionInt32
                              length:3 chunkSize:0
                         compression:TTIOCompressionNone compressionLevel:0
                               error:&err];
        [ds writeAll:packInt32(v, 3) error:&err];
    }
    // INT64
    {
        int64_t v[] = {(int64_t)-9e18, 0, (int64_t)9e18};
        id<TTIOStorageDataset> ds =
            [root createDatasetNamed:@"i64" precision:TTIOPrecisionInt64
                              length:3 chunkSize:0
                         compression:TTIOCompressionNone compressionLevel:0
                               error:&err];
        [ds writeAll:packInt64(v, 3) error:&err];
    }
    // UINT32
    {
        uint32_t v[] = {0, 1, 4294967295U};
        id<TTIOStorageDataset> ds =
            [root createDatasetNamed:@"u32" precision:TTIOPrecisionUInt32
                              length:3 chunkSize:0
                         compression:TTIOCompressionNone compressionLevel:0
                               error:&err];
        [ds writeAll:packUInt32(v, 3) error:&err];
    }
    // COMPLEX128 (3 complex numbers = 6 doubles)
    {
        double v[] = {1.0, 0.0, -1.0, 2.0, 0.0, -3.14};
        id<TTIOStorageDataset> ds =
            [root createDatasetNamed:@"c128" precision:TTIOPrecisionComplex128
                              length:3 chunkSize:0
                         compression:TTIOCompressionNone compressionLevel:0
                               error:&err];
        [ds writeAll:packComplex128(v, 3) error:&err];
    }

    [p close];

    // Reopen and verify
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];

    // FLOAT32
    {
        id<TTIOStorageDataset> ds = [root openDatasetNamed:@"f32" error:&err];
        PASS(ds != nil, "Sqlite precisions: FLOAT32 open");
        PASS(ds.precision == TTIOPrecisionFloat32, "Sqlite precisions: FLOAT32 precision");
        NSData *back = [ds readAll:&err];
        PASS(back.length == 3 * sizeof(float), "Sqlite precisions: FLOAT32 length");
        const float *gv = (const float *)back.bytes;
        PASS(gv[0] == 1.5f && gv[1] == -2.5f, "Sqlite precisions: FLOAT32 values");
    }
    // FLOAT64
    {
        id<TTIOStorageDataset> ds = [root openDatasetNamed:@"f64" error:&err];
        PASS(ds != nil, "Sqlite precisions: FLOAT64 open");
        PASS(ds.precision == TTIOPrecisionFloat64, "Sqlite precisions: FLOAT64 precision");
        NSData *back = [ds readAll:&err];
        PASS(back.length == 3 * sizeof(double), "Sqlite precisions: FLOAT64 length");
        const double *gv = (const double *)back.bytes;
        PASS(fabs(gv[2] - 3.14159265358979) < 1e-14, "Sqlite precisions: FLOAT64 values");
    }
    // INT32
    {
        id<TTIOStorageDataset> ds = [root openDatasetNamed:@"i32" error:&err];
        PASS(ds != nil, "Sqlite precisions: INT32 open");
        PASS(ds.precision == TTIOPrecisionInt32, "Sqlite precisions: INT32 precision");
        NSData *back = [ds readAll:&err];
        const int32_t *gv = (const int32_t *)back.bytes;
        PASS(gv[0] == -1000000 && gv[2] == 2147483647, "Sqlite precisions: INT32 values");
    }
    // INT64
    {
        id<TTIOStorageDataset> ds = [root openDatasetNamed:@"i64" error:&err];
        PASS(ds != nil, "Sqlite precisions: INT64 open");
        PASS(ds.precision == TTIOPrecisionInt64, "Sqlite precisions: INT64 precision");
        NSData *back = [ds readAll:&err];
        PASS(back.length == 3 * sizeof(int64_t), "Sqlite precisions: INT64 length");
        const int64_t *gv = (const int64_t *)back.bytes;
        PASS(gv[1] == 0, "Sqlite precisions: INT64 values");
    }
    // UINT32
    {
        id<TTIOStorageDataset> ds = [root openDatasetNamed:@"u32" error:&err];
        PASS(ds != nil, "Sqlite precisions: UINT32 open");
        PASS(ds.precision == TTIOPrecisionUInt32, "Sqlite precisions: UINT32 precision");
        NSData *back = [ds readAll:&err];
        const uint32_t *gv = (const uint32_t *)back.bytes;
        PASS(gv[2] == 4294967295U, "Sqlite precisions: UINT32 max value");
    }
    // COMPLEX128
    {
        id<TTIOStorageDataset> ds = [root openDatasetNamed:@"c128" error:&err];
        PASS(ds != nil, "Sqlite precisions: COMPLEX128 open");
        PASS(ds.precision == TTIOPrecisionComplex128, "Sqlite precisions: COMPLEX128 precision");
        NSData *back = [ds readAll:&err];
        PASS(back.length == 3 * 2 * sizeof(double), "Sqlite precisions: COMPLEX128 length");
        const double *gv = (const double *)back.bytes;
        PASS(gv[0] == 1.0 && gv[1] == 0.0, "Sqlite precisions: COMPLEX128 re/im[0]");
    }

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 10: Read-only mode rejects writes
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteReadOnlyRejectsWrites(void)
{
    NSString *path = sqliteTmpPath(@"readonly");
    NSError *err = nil;

    // Create a store with data
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    [root createGroupNamed:@"g1" error:&err];
    [p close];

    // Re-open read-only
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];

    // createGroup should fail
    err = nil;
    id<TTIOStorageGroup> badGroup = [root createGroupNamed:@"g2" error:&err];
    PASS(badGroup == nil, "Sqlite read-only: createGroup returns nil");
    PASS(err != nil, "Sqlite read-only: createGroup sets error");

    // createDataset should fail
    err = nil;
    id<TTIOStorageDataset> badDs =
        [root createDatasetNamed:@"d1" precision:TTIOPrecisionFloat64
                          length:4 chunkSize:0
                     compression:TTIOCompressionNone compressionLevel:0
                           error:&err];
    PASS(badDs == nil, "Sqlite read-only: createDataset returns nil");
    PASS(err != nil, "Sqlite read-only: createDataset sets error");

    // setAttribute should fail
    err = nil;
    BOOL ok = [root setAttributeValue:@"bad" forName:@"key" error:&err];
    PASS(!ok, "Sqlite read-only: setAttribute returns NO");
    PASS(err != nil, "Sqlite read-only: setAttribute sets error");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 11: TTI-O-shaped tree round-trip
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteTTIOTree(void)
{
    NSString *path = sqliteTmpPath(@"tree");
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeCreate
            provider:@"sqlite" error:&err];

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    [root setAttributeValue:@"TTI-O test run" forName:@"description" error:&err];

    id<TTIOStorageGroup> runs = [root createGroupNamed:@"runs" error:&err];

    id<TTIOStorageGroup> run1 = [runs createGroupNamed:@"run_001" error:&err];
    [run1 setAttributeValue:@(1) forName:@"run_index" error:&err];

    // mz dataset
    double mz[] = {100.0, 200.5, 350.8};
    id<TTIOStorageDataset> mzDs =
        [run1 createDatasetNamed:@"mz" precision:TTIOPrecisionFloat64
                          length:3 chunkSize:0
                     compression:TTIOCompressionNone compressionLevel:0
                           error:&err];
    [mzDs writeAll:packFloat64(mz, 3) error:&err];
    [mzDs setAttributeValue:@"MS:1000514" forName:@"accession" error:&err];

    // intensity dataset
    float intensity[] = {10000.0f, 52000.0f, 3800.0f};
    id<TTIOStorageDataset> intDs =
        [run1 createDatasetNamed:@"intensity" precision:TTIOPrecisionFloat32
                          length:3 chunkSize:0
                     compression:TTIOCompressionNone compressionLevel:0
                           error:&err];
    [intDs writeAll:packFloat32(intensity, 3) error:&err];

    // Identifications compound dataset
    NSArray *idFields = @[
        [TTIOCompoundField fieldWithName:@"peptide" kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"score"   kind:TTIOCompoundFieldKindFloat64],
    ];
    NSArray *idRows = @[
        @{@"peptide": @"PEPTIDEK", @"score": @(0.99)},
        @{@"peptide": @"ACDEFGHIK", @"score": @(0.87)},
    ];
    id<TTIOStorageGroup> ids = [run1 createGroupNamed:@"identifications" error:&err];
    id<TTIOStorageDataset> idDs =
        [ids createCompoundDatasetNamed:@"psms" fields:idFields count:2 error:&err];
    [idDs writeAll:idRows error:&err];

    [p close];

    // Verify full tree
    p = [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    root = [p rootGroupWithError:&err];
    PASS(root != nil, "Sqlite tree: root");

    id<NSObject> desc = [root attributeValueForName:@"description" error:&err];
    PASS([(NSString *)desc isEqualToString:@"TTI-O test run"],
         "Sqlite tree: root description");

    runs = [root openGroupNamed:@"runs" error:&err];
    PASS(runs != nil, "Sqlite tree: runs group");
    run1 = [runs openGroupNamed:@"run_001" error:&err];
    PASS(run1 != nil, "Sqlite tree: run_001 group");

    id<NSObject> ri = [run1 attributeValueForName:@"run_index" error:&err];
    PASS([(NSNumber *)ri longLongValue] == 1, "Sqlite tree: run_index");

    mzDs = [run1 openDatasetNamed:@"mz" error:&err];
    PASS(mzDs != nil, "Sqlite tree: mz dataset");
    NSData *mzBack = [mzDs readAll:&err];
    const double *mzg = (const double *)mzBack.bytes;
    PASS(fabs(mzg[1] - 200.5) < 1e-12, "Sqlite tree: mz[1]");

    id<NSObject> acc = [mzDs attributeValueForName:@"accession" error:&err];
    PASS([(NSString *)acc isEqualToString:@"MS:1000514"],
         "Sqlite tree: mz accession");

    intDs = [run1 openDatasetNamed:@"intensity" error:&err];
    NSData *intBack = [intDs readAll:&err];
    const float *ig = (const float *)intBack.bytes;
    PASS(ig[1] == 52000.0f, "Sqlite tree: intensity[1]");

    ids = [run1 openGroupNamed:@"identifications" error:&err];
    idDs = [ids openDatasetNamed:@"psms" error:&err];
    PASS(idDs != nil, "Sqlite tree: psms dataset");
    NSArray *psmsBack = [idDs readAll:&err];
    PASS(psmsBack.count == 2, "Sqlite tree: psms count");
    PASS([psmsBack[0][@"peptide"] isEqualToString:@"PEPTIDEK"],
         "Sqlite tree: psms[0] peptide");

    [p close];
    unlink([path fileSystemRepresentation]);
}

// ────────────────────────────────────────────────────────────────────────────
// TEST 12: Cross-language compat — read Python-written file if present
// ────────────────────────────────────────────────────────────────────────────

static void testSqliteCrossLanguageCompat(void)
{
    // This test is opportunistic: the Python-written file may not exist in CI.
    // It passes trivially if the file is absent.
    const char *xp = "/tmp/xc.tio.sqlite";
    if (access(xp, F_OK) != 0) {
        PASS(YES, "Sqlite cross-lang: file absent, skipping (OK)");
        return;
    }

    NSString *path = [NSString stringWithUTF8String:xp];
    NSError *err = nil;
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:path mode:TTIOStorageOpenModeRead
            provider:@"sqlite" error:&err];
    PASS(p != nil, "Sqlite cross-lang: open Python-written file");
    if (!p) return;

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    PASS(root != nil, "Sqlite cross-lang: rootGroup");

    // Python wrote root.set_attribute("title", "cross-lang test")
    id title = [root attributeValueForName:@"title" error:&err];
    PASS([(NSString *)title isEqualToString:@"cross-lang test"],
         "Sqlite cross-lang: root title");

    // Python wrote root.create_dataset("intensity", precision=FLOAT64, length=4)
    // with data [1.5, 2.5, 3.5, 4.5]
    id<TTIOStorageDataset> ds = [root openDatasetNamed:@"intensity" error:&err];
    PASS(ds != nil, "Sqlite cross-lang: intensity dataset");
    if (ds) {
        PASS(ds.precision == TTIOPrecisionFloat64,
             "Sqlite cross-lang: intensity precision FLOAT64");
        NSData *back = [ds readAll:&err];
        PASS(back.length == 4 * sizeof(double),
             "Sqlite cross-lang: intensity length 4 doubles");
        const double *gv = (const double *)back.bytes;
        PASS(fabs(gv[0] - 1.5) < 1e-14 &&
             fabs(gv[1] - 2.5) < 1e-14 &&
             fabs(gv[2] - 3.5) < 1e-14 &&
             fabs(gv[3] - 4.5) < 1e-14,
             "Sqlite cross-lang: intensity values [1.5,2.5,3.5,4.5]");
    }

    [p close];
}

// ────────────────────────────────────────────────────────────────────────────
// Entry point
// ────────────────────────────────────────────────────────────────────────────

void testSqliteProvider(void)
{
    testSqliteRegistration();        //  1 assertion
    testSqliteLifecycle();           //  4 assertions
    testSqliteGroupHierarchy();      // 12 assertions
    testSqlitePrimitive1D();         // 11 assertions
    testSqlitePrimitiveND();         //  9 assertions
    testSqliteCompound();            // 16 assertions
    testSqliteGroupAttributes();     // 14 assertions
    testSqliteDatasetAttributes();   // 10 assertions
    testSqliteAllPrecisions();       // 21 assertions
    testSqliteReadOnlyRejectsWrites(); // 6 assertions
    testSqliteTTIOTree();            // 15 assertions
    testSqliteCrossLanguageCompat(); //  1–7 assertions (opportunistic)
}
// Total guaranteed: ~119 assertions
