/*
 * TestMilestone52 — ObjC TTIOZarrProvider round-trip tests (v0.8 M52).
 *
 * Covers primitive 1-D + N-D, compound dataset, attributes, provider
 * registry discovery. Cross-language parity with Python and Java is
 * validated in a separate Python-driven harness that shells out to a
 * ttio_zarr_cross_compat tool (also added in M52).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Providers/TTIOZarrProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOCompoundField.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *m52TempDir(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m52_%d_%@.zarr",
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
        [[TTIOProviderRegistry sharedRegistry] knownProviderNames];
    PASS([names containsObject:@"zarr"],
         "M52: TTIOZarrProvider auto-registered as 'zarr'");

    // ── Primitive 1-D round trip ──

    NSString *path = m52TempDir(@"prim1d");
    rm_rf(path);

    TTIOZarrProvider *p = [[TTIOZarrProvider alloc] init];
    NSError *err = nil;
    PASS([p openURL:path mode:TTIOStorageOpenModeCreate error:&err],
         "M52: openURL mode=Create");

    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    PASS(root != nil, "M52: rootGroup non-nil");

    id<TTIOStorageDataset> ds =
        [root createDatasetNamed:@"signal"
                        precision:TTIOPrecisionFloat64
                           length:64
                        chunkSize:0
                      compression:TTIOCompressionNone
                 compressionLevel:0
                            error:&err];
    PASS(ds != nil, "M52: create float64 dataset (64 elements)");

    double vals[64];
    for (int i = 0; i < 64; i++) vals[i] = (double)i / 2.0;
    NSData *payload = [NSData dataWithBytes:vals length:sizeof(vals)];
    PASS([ds writeAll:payload error:&err], "M52: writeAll payload");
    [p close];

    // Reopen + read back.
    TTIOZarrProvider *p2 = [[TTIOZarrProvider alloc] init];
    PASS([p2 openURL:path mode:TTIOStorageOpenModeRead error:&err],
         "M52: openURL mode=Read");
    id<TTIOStorageGroup> root2 = [p2 rootGroupWithError:&err];
    id<TTIOStorageDataset> ds2 = [root2 openDatasetNamed:@"signal" error:&err];
    PASS(ds2 != nil, "M52: open float64 dataset back");
    PASS([ds2 precision] == TTIOPrecisionFloat64,
         "M52: precision round-trips as float64");
    PASS([ds2 length] == 64, "M52: length round-trips as 64");
    NSData *back = [ds2 readAll:&err];
    PASS([back isEqualToData:payload], "M52: float64 bytes round-trip exactly");
    [p2 close];
    rm_rf(path);

    // ── N-D (rank 2) with multi-chunk ──

    path = m52TempDir(@"nd");
    rm_rf(path);

    TTIOZarrProvider *p3 = [[TTIOZarrProvider alloc] init];
    PASS([p3 openURL:path mode:TTIOStorageOpenModeCreate error:&err],
         "M52: create N-D store");
    id<TTIOStorageGroup> root3 = [p3 rootGroupWithError:&err];
    NSArray *shape  = @[@(4), @(6)];
    NSArray *chunks = @[@(2), @(3)];
    id<TTIOStorageDataset> dsN =
        [root3 createDatasetNDNamed:@"grid"
                           precision:TTIOPrecisionInt32
                               shape:shape
                              chunks:chunks
                         compression:TTIOCompressionNone
                    compressionLevel:0
                               error:&err];
    PASS(dsN != nil, "M52: create N-D int32 grid 4×6 chunked 2×3");
    int32_t grid[24];
    for (int i = 0; i < 24; i++) grid[i] = i * 7;
    NSData *gridData = [NSData dataWithBytes:grid length:sizeof(grid)];
    PASS([dsN writeAll:gridData error:&err], "M52: write N-D grid");
    [p3 close];

    TTIOZarrProvider *p4 = [[TTIOZarrProvider alloc] init];
    [p4 openURL:path mode:TTIOStorageOpenModeRead error:&err];
    id<TTIOStorageDataset> dsN2 =
        [[p4 rootGroupWithError:&err] openDatasetNamed:@"grid" error:&err];
    NSData *backN = [dsN2 readAll:&err];
    PASS([backN isEqualToData:gridData],
         "M52: N-D multi-chunk bytes round-trip exactly");
    [p4 close];
    rm_rf(path);

    // ── Compound dataset ──

    path = m52TempDir(@"compound");
    rm_rf(path);

    TTIOZarrProvider *p5 = [[TTIOZarrProvider alloc] init];
    [p5 openURL:path mode:TTIOStorageOpenModeCreate error:&err];
    id<TTIOStorageGroup> root5 = [p5 rootGroupWithError:&err];
    NSArray<TTIOCompoundField *> *fields = @[
        [[TTIOCompoundField alloc] initWithName:@"ident_id"
                                            kind:TTIOCompoundFieldKindVLString],
        [[TTIOCompoundField alloc] initWithName:@"spectrum_index"
                                            kind:TTIOCompoundFieldKindUInt32],
        [[TTIOCompoundField alloc] initWithName:@"mass_error"
                                            kind:TTIOCompoundFieldKindFloat64],
    ];
    id<TTIOStorageDataset> cds =
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

    TTIOZarrProvider *p6 = [[TTIOZarrProvider alloc] init];
    [p6 openURL:path mode:TTIOStorageOpenModeRead error:&err];
    id<TTIOStorageDataset> cdsRead =
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
    TTIOZarrProvider *p7 = [[TTIOZarrProvider alloc] init];
    [p7 openURL:path mode:TTIOStorageOpenModeCreate error:&err];
    id<TTIOStorageGroup> root7 = [p7 rootGroupWithError:&err];
    [root7 setAttributeValue:@"demo" forName:@"title" error:&err];
    [root7 setAttributeValue:@(42) forName:@"count" error:&err];
    [p7 close];

    TTIOZarrProvider *p8 = [[TTIOZarrProvider alloc] init];
    [p8 openURL:path mode:TTIOStorageOpenModeRead error:&err];
    id<TTIOStorageGroup> root8 = [p8 rootGroupWithError:&err];
    PASS([[root8 attributeValueForName:@"title" error:&err] isEqual:@"demo"],
         "M52: string attribute round-trips");
    PASS([[root8 attributeValueForName:@"count" error:&err] longLongValue] == 42,
         "M52: int attribute round-trips");
    [p8 close];
    rm_rf(path);
}
