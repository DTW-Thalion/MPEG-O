/*
 * TestMilestone52 — ObjC MPGOZarrProvider round-trip tests (v0.8 M52).
 *
 * Covers primitive 1-D + N-D, compound dataset, attributes, provider
 * registry discovery. Cross-language parity with Python and Java is
 * validated in a separate Python-driven harness that shells out to a
 * mpgo_zarr_cross_compat tool (also added in M52).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Providers/MPGOZarrProvider.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOCompoundField.h"
#import "Providers/MPGOStorageProtocols.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *m52TempDir(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m52_%d_%@.zarr",
            (int)getpid(), suffix];
}

static void rm_rf(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

void testMilestone52(void)
{
    // ── Registry wiring (+load runs at lib load time) ──

    NSArray<NSString *> *names =
        [[MPGOProviderRegistry sharedRegistry] knownProviderNames];
    PASS([names containsObject:@"zarr"],
         "M52: MPGOZarrProvider auto-registered as 'zarr'");

    // ── Primitive 1-D round trip ──

    NSString *path = m52TempDir(@"prim1d");
    rm_rf(path);

    MPGOZarrProvider *p = [[MPGOZarrProvider alloc] init];
    NSError *err = nil;
    PASS([p openURL:path mode:MPGOStorageOpenModeCreate error:&err],
         "M52: openURL mode=Create");

    id<MPGOStorageGroup> root = [p rootGroupWithError:&err];
    PASS(root != nil, "M52: rootGroup non-nil");

    id<MPGOStorageDataset> ds =
        [root createDatasetNamed:@"signal"
                        precision:MPGOPrecisionFloat64
                           length:64
                        chunkSize:0
                      compression:MPGOCompressionNone
                 compressionLevel:0
                            error:&err];
    PASS(ds != nil, "M52: create float64 dataset (64 elements)");

    double vals[64];
    for (int i = 0; i < 64; i++) vals[i] = (double)i / 2.0;
    NSData *payload = [NSData dataWithBytes:vals length:sizeof(vals)];
    PASS([ds writeAll:payload error:&err], "M52: writeAll payload");
    [p close];

    // Reopen + read back.
    MPGOZarrProvider *p2 = [[MPGOZarrProvider alloc] init];
    PASS([p2 openURL:path mode:MPGOStorageOpenModeRead error:&err],
         "M52: openURL mode=Read");
    id<MPGOStorageGroup> root2 = [p2 rootGroupWithError:&err];
    id<MPGOStorageDataset> ds2 = [root2 openDatasetNamed:@"signal" error:&err];
    PASS(ds2 != nil, "M52: open float64 dataset back");
    PASS([ds2 precision] == MPGOPrecisionFloat64,
         "M52: precision round-trips as float64");
    PASS([ds2 length] == 64, "M52: length round-trips as 64");
    NSData *back = [ds2 readAll:&err];
    PASS([back isEqualToData:payload], "M52: float64 bytes round-trip exactly");
    [p2 close];
    rm_rf(path);

    // ── N-D (rank 2) with multi-chunk ──

    path = m52TempDir(@"nd");
    rm_rf(path);

    MPGOZarrProvider *p3 = [[MPGOZarrProvider alloc] init];
    PASS([p3 openURL:path mode:MPGOStorageOpenModeCreate error:&err],
         "M52: create N-D store");
    id<MPGOStorageGroup> root3 = [p3 rootGroupWithError:&err];
    NSArray *shape  = @[@(4), @(6)];
    NSArray *chunks = @[@(2), @(3)];
    id<MPGOStorageDataset> dsN =
        [root3 createDatasetNDNamed:@"grid"
                           precision:MPGOPrecisionInt32
                               shape:shape
                              chunks:chunks
                         compression:MPGOCompressionNone
                    compressionLevel:0
                               error:&err];
    PASS(dsN != nil, "M52: create N-D int32 grid 4×6 chunked 2×3");
    int32_t grid[24];
    for (int i = 0; i < 24; i++) grid[i] = i * 7;
    NSData *gridData = [NSData dataWithBytes:grid length:sizeof(grid)];
    PASS([dsN writeAll:gridData error:&err], "M52: write N-D grid");
    [p3 close];

    MPGOZarrProvider *p4 = [[MPGOZarrProvider alloc] init];
    [p4 openURL:path mode:MPGOStorageOpenModeRead error:&err];
    id<MPGOStorageDataset> dsN2 =
        [[p4 rootGroupWithError:&err] openDatasetNamed:@"grid" error:&err];
    NSData *backN = [dsN2 readAll:&err];
    PASS([backN isEqualToData:gridData],
         "M52: N-D multi-chunk bytes round-trip exactly");
    [p4 close];
    rm_rf(path);

    // ── Compound dataset ──

    path = m52TempDir(@"compound");
    rm_rf(path);

    MPGOZarrProvider *p5 = [[MPGOZarrProvider alloc] init];
    [p5 openURL:path mode:MPGOStorageOpenModeCreate error:&err];
    id<MPGOStorageGroup> root5 = [p5 rootGroupWithError:&err];
    NSArray<MPGOCompoundField *> *fields = @[
        [[MPGOCompoundField alloc] initWithName:@"ident_id"
                                            kind:MPGOCompoundFieldKindVLString],
        [[MPGOCompoundField alloc] initWithName:@"spectrum_index"
                                            kind:MPGOCompoundFieldKindUInt32],
        [[MPGOCompoundField alloc] initWithName:@"mass_error"
                                            kind:MPGOCompoundFieldKindFloat64],
    ];
    id<MPGOStorageDataset> cds =
        [root5 createCompoundDatasetNamed:@"identifications"
                                     fields:fields
                                      count:3
                                      error:&err];
    PASS(cds != nil, "M52: create compound dataset");
    NSArray<NSDictionary *> *rows = @[
        @{@"ident_id":@"id-0", @"spectrum_index":@(100), @"mass_error":@(0.0)},
        @{@"ident_id":@"id-1", @"spectrum_index":@(101), @"mass_error":@(0.5)},
        @{@"ident_id":@"id-2", @"spectrum_index":@(102), @"mass_error":@(1.0)},
    ];
    PASS([cds writeAll:rows error:&err], "M52: compound writeAll rows");
    [p5 close];

    MPGOZarrProvider *p6 = [[MPGOZarrProvider alloc] init];
    [p6 openURL:path mode:MPGOStorageOpenModeRead error:&err];
    id<MPGOStorageDataset> cdsRead =
        [[p6 rootGroupWithError:&err] openDatasetNamed:@"identifications"
                                                   error:&err];
    PASS(cdsRead != nil, "M52: open compound dataset back");
    NSArray<NSDictionary *> *back2 = [cdsRead readAll:&err];
    PASS(back2.count == 3, "M52: compound read returns 3 rows");
    PASS([back2[1][@"ident_id"] isEqual:@"id-1"],
         "M52: compound VL-string field round-trips");
    PASS([back2[1][@"spectrum_index"] longLongValue] == 101,
         "M52: compound uint32 field round-trips");
    PASS(fabs([back2[1][@"mass_error"] doubleValue] - 0.5) < 1e-12,
         "M52: compound float64 field round-trips");

    // Canonical bytes: 3 rows × (u32(len)+utf8(id-N)=4+4 || u32(idx)=4 || f64(err)=8) = 3 × 20 = 60 bytes
    NSData *canon = [cdsRead readCanonicalBytes:&err];
    PASS(canon.length == 60,
         "M52: compound canonical bytes match spec (60 bytes for 3 rows)");
    [p6 close];
    rm_rf(path);

    // ── Attributes on a group + dataset ──

    path = m52TempDir(@"attrs");
    rm_rf(path);
    MPGOZarrProvider *p7 = [[MPGOZarrProvider alloc] init];
    [p7 openURL:path mode:MPGOStorageOpenModeCreate error:&err];
    id<MPGOStorageGroup> root7 = [p7 rootGroupWithError:&err];
    [root7 setAttributeValue:@"demo" forName:@"title" error:&err];
    [root7 setAttributeValue:@(42) forName:@"count" error:&err];
    [p7 close];

    MPGOZarrProvider *p8 = [[MPGOZarrProvider alloc] init];
    [p8 openURL:path mode:MPGOStorageOpenModeRead error:&err];
    id<MPGOStorageGroup> root8 = [p8 rootGroupWithError:&err];
    PASS([[root8 attributeValueForName:@"title" error:&err] isEqual:@"demo"],
         "M52: string attribute round-trips");
    PASS([[root8 attributeValueForName:@"count" error:&err] longLongValue] == 42,
         "M52: int attribute round-trips");
    [p8 close];
    rm_rf(path);
}
