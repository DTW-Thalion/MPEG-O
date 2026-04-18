// TestCanonicalBytesCrossBackend.m — v0.7 M43.
//
// The canonical byte form is the signing / encryption contract that
// spans backends. A file signed via HDF5 must verify via Memory /
// SQLite, and vice versa. These tests pin the invariant.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOCompoundField.h"
#import "Providers/MPGOMemoryProvider.h"
#import "Providers/MPGOCanonicalBytes.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>

static NSString *m43TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m43_%d_%@",
            (int)getpid(), suffix];
}

static NSData *leFloat64Bytes(const double *values, NSUInteger count)
{
    NSMutableData *d = [NSMutableData dataWithLength:count * 8];
    memcpy(d.mutableBytes, values, count * 8);
    return d;
}

static NSData *canonicalPrimitiveThroughProvider(NSString *providerName,
                                                  NSString *url,
                                                  const double *values,
                                                  NSUInteger count)
{
    NSError *err = nil;
    id<MPGOStorageProvider> p =
        [[MPGOProviderRegistry sharedRegistry]
            openURL:url
               mode:MPGOStorageOpenModeCreate
           provider:providerName
              error:&err];
    if (!p) return nil;
    id<MPGOStorageGroup> root = [p rootGroupWithError:&err];
    id<MPGOStorageDataset> ds =
        [root createDatasetNamed:@"v"
                        precision:MPGOPrecisionFloat64
                           length:count
                        chunkSize:0
                      compression:MPGOCompressionNone
                 compressionLevel:0
                            error:&err];
    [ds writeAll:leFloat64Bytes(values, count) error:&err];
    [p close];

    p = [[MPGOProviderRegistry sharedRegistry]
            openURL:url
               mode:MPGOStorageOpenModeRead
           provider:providerName
              error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"v" error:&err];
    NSData *canonical = [ds readCanonicalBytes:&err];
    [p close];
    return canonical;
}

void testCanonicalBytesCrossBackend(void)
{
    // ── Primitive FLOAT64 identity across HDF5 / Memory / SQLite ──
    const double values[4] = { 1.0, -2.5, 3.14159, 1e-10 };
    NSData *expected = leFloat64Bytes(values, 4);

    NSString *hdf5Path = m43TempPath(@"primitive.mpgo");
    NSString *memUrl   = [NSString stringWithFormat:@"memory://m43-%d", (int)getpid()];
    NSString *sqlPath  = m43TempPath(@"primitive.mpgo.sqlite");
    unlink([hdf5Path fileSystemRepresentation]);
    unlink([sqlPath fileSystemRepresentation]);
    [MPGOMemoryProvider discardStore:memUrl];

    NSData *hdf5Bytes   = canonicalPrimitiveThroughProvider(@"hdf5", hdf5Path, values, 4);
    NSData *memoryBytes = canonicalPrimitiveThroughProvider(@"memory", memUrl, values, 4);
    NSData *sqliteBytes = canonicalPrimitiveThroughProvider(@"sqlite", sqlPath, values, 4);

    PASS(hdf5Bytes != nil, "M43: HDF5 readCanonicalBytes returned data");
    PASS(memoryBytes != nil, "M43: Memory readCanonicalBytes returned data");
    PASS(sqliteBytes != nil, "M43: SQLite readCanonicalBytes returned data");
    PASS([hdf5Bytes isEqualToData:expected],
         "M43: HDF5 canonical bytes match expected little-endian packing");
    PASS([memoryBytes isEqualToData:expected],
         "M43: Memory canonical bytes match expected little-endian packing");
    PASS([sqliteBytes isEqualToData:expected],
         "M43: SQLite canonical bytes match expected little-endian packing");
    PASS([hdf5Bytes isEqualToData:memoryBytes],
         "M43: HDF5 ↔ Memory cross-backend byte identity");
    PASS([memoryBytes isEqualToData:sqliteBytes],
         "M43: Memory ↔ SQLite cross-backend byte identity");

    unlink([hdf5Path fileSystemRepresentation]);
    unlink([sqlPath fileSystemRepresentation]);
    [MPGOMemoryProvider discardStore:memUrl];

    // ── Compound canonical bytes via the static helper ──
    NSArray<MPGOCompoundField *> *fields = @[
        [MPGOCompoundField fieldWithName:@"run_name" kind:MPGOCompoundFieldKindVLString],
        [MPGOCompoundField fieldWithName:@"spectrum_index" kind:MPGOCompoundFieldKindUInt32],
        [MPGOCompoundField fieldWithName:@"score" kind:MPGOCompoundFieldKindFloat64],
        [MPGOCompoundField fieldWithName:@"chem_id" kind:MPGOCompoundFieldKindVLString],
    ];
    NSArray<NSDictionary *> *rows = @[
        @{ @"run_name": @"runA", @"spectrum_index": @0,  @"score": @0.95, @"chem_id": @"CHEBI:15377" },
        @{ @"run_name": @"runB", @"spectrum_index": @3,  @"score": @0.72, @"chem_id": @"HMDB:0001234" },
        @{ @"run_name": @"",     @"spectrum_index": @42, @"score": @-1.5, @"chem_id": @"" },
    ];
    NSData *compoundCanonical =
        [MPGOCanonicalBytes canonicalBytesForCompoundRows:rows fields:fields];

    // Manual assembly of the first row: "runA" (4 bytes) + 0 + 0.95 + "CHEBI:15377"
    NSMutableData *expectedFirstRow = [NSMutableData data];
    uint8_t runALen[4]  = { 4, 0, 0, 0 };
    [expectedFirstRow appendBytes:runALen length:4];
    [expectedFirstRow appendBytes:"runA" length:4];
    uint8_t zeroIdx[4]  = { 0, 0, 0, 0 };
    [expectedFirstRow appendBytes:zeroIdx length:4];
    double score = 0.95;
    [expectedFirstRow appendBytes:&score length:8];
    uint8_t chebiLen[4] = { 11, 0, 0, 0 };
    [expectedFirstRow appendBytes:chebiLen length:4];
    [expectedFirstRow appendBytes:"CHEBI:15377" length:11];

    PASS(compoundCanonical.length >= expectedFirstRow.length
         && memcmp(compoundCanonical.bytes, expectedFirstRow.bytes,
                   expectedFirstRow.length) == 0,
         "M43: compound canonical bytes match hand-computed first row");
}
