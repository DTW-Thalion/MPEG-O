/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Extendable datasets, writeSlice and the UInt64 compound kind on the
 * four storage providers.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOCompoundField.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

static NSString *pxUrl(NSString *provider)
{
    if ([provider isEqualToString:@"memory"]) {
        return [NSString stringWithFormat:@"memory://px-%d-%u", (int)getpid(), arc4random()];
    }
    NSString *ext = [provider isEqualToString:@"sqlite"] ? @"sqlite"
                  : [provider isEqualToString:@"zarr"] ? @"zarr" : @"h5";
    NSString *p = [NSString stringWithFormat:@"/tmp/ttio_px_%d_%u_%@.%@",
                   (int)getpid(), arc4random(), provider, ext];
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    return p;
}

static NSData *bytesOf(const uint8_t *b, NSUInteger n) { return [NSData dataWithBytes:b length:n]; }

static void pxPrimitive(NSString *provider)
{
    NSError *err = nil;
    TTIOProviderRegistry *reg = [TTIOProviderRegistry sharedRegistry];
    NSString *url = pxUrl(provider);
    id<TTIOStorageProvider> p = [reg openURL:url mode:TTIOStorageOpenModeCreate provider:provider error:&err];
    PASS(p != nil, "%s: create", [provider UTF8String]);
    if (!p) return;
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];

    id<TTIOStorageDataset> ds = [root createDatasetNamed:@"blob" precision:TTIOPrecisionUInt8
                                                  length:0 chunkSize:4
                                             compression:TTIOCompressionNone compressionLevel:0
                                              extendable:YES error:&err];
    PASS(ds != nil, "%s: extendable uint8 created (%s)", [provider UTF8String],
         [[err localizedDescription] UTF8String] ?: "");
    if (!ds) { [p close]; return; }
    PASS([ds isExtendable], "%s: isExtendable", [provider UTF8String]);
    PASS([ds length] == 0, "%s: length 0 at create", [provider UTF8String]);
    const uint8_t a[3] = {1, 2, 3};
    const uint8_t b[5] = {4, 5, 6, 7, 8};
    PASS([ds appendData:bytesOf(a, 3) error:&err], "%s: append 3", [provider UTF8String]);
    PASS([ds appendData:bytesOf(b, 5) error:&err], "%s: append 5", [provider UTF8String]);
    PASS([ds appendData:[NSData data] error:&err], "%s: append 0", [provider UTF8String]);
    PASS([ds length] == 8, "%s: length 8 after appends (%lu)", [provider UTF8String], (unsigned long)[ds length]);
    NSData *mid = [ds readSliceAtOffset:2 count:4 error:&err];
    const uint8_t expMid[4] = {3, 4, 5, 6};
    PASS([mid isEqualToData:bytesOf(expMid, 4)], "%s: slice across the append boundary", [provider UTF8String]);
    const uint8_t patch[2] = {9, 9};
    PASS([ds writeSlice:bytesOf(patch, 2) atOffset:1 error:&err], "%s: writeSlice", [provider UTF8String]);
    const uint8_t expAll[8] = {1, 9, 9, 4, 5, 6, 7, 8};
    PASS([[ds readAll:&err] isEqualToData:bytesOf(expAll, 8)], "%s: readAll after writeSlice", [provider UTF8String]);

    id<TTIOStorageDataset> vals = [root createDatasetNamed:@"vals" precision:TTIOPrecisionFloat64
                                                    length:0 chunkSize:2
                                               compression:TTIOCompressionNone compressionLevel:0
                                                extendable:YES error:&err];
    const double d[3] = {1.5, 2.5, 3.5};
    PASS([vals appendData:[NSData dataWithBytes:d length:24] error:&err], "%s: append doubles", [provider UTF8String]);
    NSData *tail = [vals readSliceAtOffset:1 count:2 error:&err];
    BOOL tailOk = tail.length == 16 && ((const double *)tail.bytes)[0] == 2.5 && ((const double *)tail.bytes)[1] == 3.5;
    PASS(tailOk, "%s: double slice", [provider UTF8String]);

    id<TTIOStorageDataset> fixed = [root createDatasetNamed:@"fixed" precision:TTIOPrecisionUInt8
                                                     length:2 chunkSize:0
                                                compression:TTIOCompressionNone compressionLevel:0
                                                      error:&err];
    PASS(![fixed isExtendable], "%s: fixed dataset not extendable", [provider UTF8String]);
    err = nil;
    BOOL fixedRefused = ![fixed appendData:bytesOf(a, 1) error:&err] && err != nil;
    PASS(fixedRefused, "%s: append on a fixed dataset fails", [provider UTF8String]);
    err = nil;
    id<TTIOStorageDataset> bad = [root createDatasetNamed:@"bad" precision:TTIOPrecisionUInt8
                                                   length:0 chunkSize:0
                                              compression:TTIOCompressionNone compressionLevel:0
                                               extendable:YES error:&err];
    BOOL badRefused = bad == nil && err != nil;
    PASS(badRefused, "%s: extendable with chunk 0 is refused", [provider UTF8String]);
    [p close];

    err = nil;
    id<TTIOStorageProvider> p2 = [reg openURL:url mode:TTIOStorageOpenModeRead provider:provider error:&err];
    id<TTIOStorageDataset> re = [[p2 rootGroupWithError:&err] openDatasetNamed:@"blob" error:&err];
    BOOL reExt = re != nil && [re isExtendable];
    PASS(reExt, "%s: reopened dataset is extendable", [provider UTF8String]);
    PASS([re length] == 8, "%s: reopened length 8", [provider UTF8String]);
    PASS([[re readAll:&err] isEqualToData:bytesOf(expAll, 8)], "%s: reopened bytes", [provider UTF8String]);
    [p2 close];
    if ([provider isEqualToString:@"memory"]) [TTIOMemoryProvider discardStore:url];
}

static void pxCompound(NSString *provider)
{
    NSError *err = nil;
    TTIOProviderRegistry *reg = [TTIOProviderRegistry sharedRegistry];
    NSString *url = pxUrl(provider);
    NSArray *fields = @[
        [TTIOCompoundField fieldWithName:@"start" kind:TTIOCompoundFieldKindUInt64],
        [TTIOCompoundField fieldWithName:@"n" kind:TTIOCompoundFieldKindUInt32],
        [TTIOCompoundField fieldWithName:@"score" kind:TTIOCompoundFieldKindFloat64],
    ];
    id<TTIOStorageProvider> p = [reg openURL:url mode:TTIOStorageOpenModeCreate provider:provider error:&err];
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    id<TTIOStorageDataset> ds = [root createCompoundDatasetNamed:@"idx" fields:fields count:0
                                                      extendable:YES chunkRows:2 error:&err];
    PASS(ds != nil, "%s: extendable compound created (%s)", [provider UTF8String],
         [[err localizedDescription] UTF8String] ?: "");
    if (!ds) { [p close]; return; }
    PASS([ds isExtendable], "%s: compound isExtendable", [provider UTF8String]);
    NSArray *one = @[@{@"start": @0, @"n": @4, @"score": @0.5}];
    NSArray *two = @[@{@"start": @4, @"n": @1, @"score": @1.5},
                     @{@"start": @5, @"n": @2, @"score": @2.5}];
    BOOL ok1 = [ds appendData:one error:&err];
    PASS(ok1, "%s: append 1 row (%s)", [provider UTF8String], [[err localizedDescription] UTF8String] ?: "");
    BOOL ok2 = [ds appendData:two error:&err];
    PASS(ok2, "%s: append 2 rows", [provider UTF8String]);
    PASS([ds length] == 3, "%s: 3 rows (%lu)", [provider UTF8String], (unsigned long)[ds length]);
    NSArray *rows = [ds readRows:&err];
    PASS(rows.count == 3, "%s: readRows 3", [provider UTF8String]);
    BOOL lastOk = rows.count == 3 && [rows[2][@"start"] unsignedLongLongValue] == 5
         && [rows[2][@"n"] unsignedIntValue] == 2 && [rows[2][@"score"] doubleValue] == 2.5;
    PASS(lastOk, "%s: last row values", [provider UTF8String]);
    [p close];

    err = nil;
    id<TTIOStorageProvider> p2 = [reg openURL:url mode:TTIOStorageOpenModeRead provider:provider error:&err];
    id<TTIOStorageDataset> re = [[p2 rootGroupWithError:&err] openDatasetNamed:@"idx" error:&err];
    NSArray *rows2 = [re readRows:&err];
    PASS(rows2.count == 3, "%s: reopened readRows 3 (%lu)", [provider UTF8String], (unsigned long)rows2.count);
    NSArray<TTIOCompoundField *> *cf = [re compoundFields];
    BOOL kindOk = cf.count == 3 && cf[0].kind == TTIOCompoundFieldKindUInt64;
    PASS(kindOk, "%s: reopened kind UInt64", [provider UTF8String]);
    NSData *canon = [re readCanonicalBytes:&err];
    PASS(canon.length == 3 * (8 + 4 + 8), "%s: canonical bytes 60 (%lu)", [provider UTF8String],
         (unsigned long)canon.length);
    [p2 close];
    if ([provider isEqualToString:@"memory"]) [TTIOMemoryProvider discardStore:url];
}

void testProviderExtendable(void)
{
    @autoreleasepool {
        for (NSString *provider in @[@"hdf5", @"memory", @"sqlite", @"zarr"]) {
            pxPrimitive(provider);
            pxCompound(provider);
        }
    }
}
