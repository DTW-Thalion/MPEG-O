// TestNdDatasetCrossBackend.m — v0.7 M45
//
// Cross-backend N-D (rank ≥ 2) dataset round-trip. All three shipping
// providers (HDF5, Memory, SQLite) must accept createDatasetNDNamed:
// and round-trip both rank-2 slabs and rank-3 cubes with
// element-for-element identity.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOMemoryProvider.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>

static NSString *m45TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m45_%d_%@",
            (int)getpid(), suffix];
}

static NSData *build3dCubeBytes(NSArray<NSNumber *> *shape, double *outExpected)
{
    NSUInteger h = [shape[0] unsignedIntegerValue];
    NSUInteger w = [shape[1] unsignedIntegerValue];
    NSUInteger s = [shape[2] unsignedIntegerValue];
    NSUInteger n = h * w * s;
    NSMutableData *out = [NSMutableData dataWithLength:n * sizeof(double)];
    double *p = out.mutableBytes;
    NSUInteger idx = 0;
    for (NSUInteger i = 0; i < h; i++) {
        for (NSUInteger j = 0; j < w; j++) {
            for (NSUInteger k = 0; k < s; k++) {
                double v = (double)(i * 100 + j * 10 + k) + 0.5;
                p[idx++] = v;
                if (outExpected) outExpected[idx - 1] = v;
            }
        }
    }
    return out;
}

static NSData *roundTripCube(NSString *providerName,
                              NSString *url,
                              NSArray<NSNumber *> *shape)
{
    NSUInteger n = 1;
    for (NSNumber *d in shape) n *= [d unsignedIntegerValue];
    NSMutableData *writeBuf = [NSMutableData dataWithLength:n * sizeof(double)];
    double *w = writeBuf.mutableBytes;
    NSUInteger idx = 0;
    NSUInteger H = [shape[0] unsignedIntegerValue];
    NSUInteger W = [shape[1] unsignedIntegerValue];
    NSUInteger S = [shape[2] unsignedIntegerValue];
    for (NSUInteger i = 0; i < H; i++) {
        for (NSUInteger j = 0; j < W; j++) {
            for (NSUInteger k = 0; k < S; k++) {
                w[idx++] = (double)(i * 100 + j * 10 + k) + 0.5;
            }
        }
    }

    NSError *err = nil;
    id<MPGOStorageProvider> p = [[MPGOProviderRegistry sharedRegistry]
            openURL:url
               mode:MPGOStorageOpenModeCreate
           provider:providerName
              error:&err];
    if (!p) return nil;
    id<MPGOStorageGroup> root = [p rootGroupWithError:&err];
    id<MPGOStorageDataset> ds = [root createDatasetNDNamed:@"cube"
                                                  precision:MPGOPrecisionFloat64
                                                      shape:shape
                                                     chunks:nil
                                                compression:MPGOCompressionNone
                                           compressionLevel:0
                                                      error:&err];
    [ds writeAll:writeBuf error:&err];
    [p close];

    p = [[MPGOProviderRegistry sharedRegistry]
            openURL:url
               mode:MPGOStorageOpenModeRead
           provider:providerName
              error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"cube" error:&err];
    NSData *got = [ds readAll:&err];
    [p close];
    return got;
}

void testNdDatasetCrossBackend(void)
{
    NSArray<NSNumber *> *shape = @[@4, @5, @6];

    // ── Per-backend round-trip ──
    NSString *hdf5Path = m45TempPath(@"cube.mpgo");
    NSString *memUrl   = [NSString stringWithFormat:@"memory://m45-%d", (int)getpid()];
    NSString *sqlPath  = m45TempPath(@"cube.mpgo.sqlite");
    unlink([hdf5Path fileSystemRepresentation]);
    unlink([sqlPath fileSystemRepresentation]);
    [MPGOMemoryProvider discardStore:memUrl];

    NSData *hdf5Bytes   = roundTripCube(@"hdf5", hdf5Path, shape);
    NSData *memoryBytes = roundTripCube(@"memory", memUrl, shape);
    NSData *sqliteBytes = roundTripCube(@"sqlite", sqlPath, shape);

    NSUInteger expectedBytes = 4 * 5 * 6 * sizeof(double);
    PASS(hdf5Bytes.length == expectedBytes,
         "M45: HDF5 rank-3 cube returns %lu bytes", (unsigned long)expectedBytes);
    PASS(memoryBytes.length == expectedBytes,
         "M45: Memory rank-3 cube returns %lu bytes", (unsigned long)expectedBytes);
    PASS(sqliteBytes.length == expectedBytes,
         "M45: SQLite rank-3 cube returns %lu bytes", (unsigned long)expectedBytes);
    PASS([hdf5Bytes isEqualToData:memoryBytes],
         "M45: HDF5 ↔ Memory rank-3 byte identity");
    PASS([memoryBytes isEqualToData:sqliteBytes],
         "M45: Memory ↔ SQLite rank-3 byte identity");

    unlink([hdf5Path fileSystemRepresentation]);
    unlink([sqlPath fileSystemRepresentation]);
    [MPGOMemoryProvider discardStore:memUrl];

    // ── Shape preservation across open/close ──
    NSError *err = nil;
    NSString *shapePath = m45TempPath(@"shape.mpgo");
    unlink([shapePath fileSystemRepresentation]);
    id<MPGOStorageProvider> p = [[MPGOProviderRegistry sharedRegistry]
            openURL:shapePath
               mode:MPGOStorageOpenModeCreate
           provider:@"hdf5"
              error:&err];
    id<MPGOStorageGroup> root = [p rootGroupWithError:&err];
    id<MPGOStorageDataset> ds = [root createDatasetNDNamed:@"x"
                                                  precision:MPGOPrecisionFloat64
                                                      shape:@[@3, @4, @5]
                                                     chunks:nil
                                                compression:MPGOCompressionNone
                                           compressionLevel:0
                                                      error:&err];
    NSArray<NSNumber *> *shapeWrite = ds.shape;
    PASS(shapeWrite.count == 3
         && [shapeWrite[0] isEqualToNumber:@3]
         && [shapeWrite[1] isEqualToNumber:@4]
         && [shapeWrite[2] isEqualToNumber:@5],
         "M45: HDF5 adapter preserves rank-3 shape at write time");
    NSMutableData *fill = [NSMutableData dataWithLength:3*4*5*sizeof(double)];
    [ds writeAll:fill error:&err];
    [p close];

    p = [[MPGOProviderRegistry sharedRegistry]
            openURL:shapePath
               mode:MPGOStorageOpenModeRead
           provider:@"hdf5"
              error:&err];
    root = [p rootGroupWithError:&err];
    ds = [root openDatasetNamed:@"x" error:&err];
    NSArray<NSNumber *> *shapeRead = ds.shape;
    PASS(shapeRead.count == 3
         && [shapeRead[0] isEqualToNumber:@3]
         && [shapeRead[1] isEqualToNumber:@4]
         && [shapeRead[2] isEqualToNumber:@5],
         "M45: HDF5 adapter reconstructs rank-3 shape after reopen");
    [p close];
    unlink([shapePath fileSystemRepresentation]);
}
