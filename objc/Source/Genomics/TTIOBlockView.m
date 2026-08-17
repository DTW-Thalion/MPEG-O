/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Genomics/TTIOBlockView.h"
#import "Genomics/TTIOBlockTable.h"
#import "Genomics/TTIOGenomicBlocks.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOCompoundField.h"
#import "ValueClasses/TTIOEnums.h"
#import <stdatomic.h>

@implementation TTIOBlockView {
    id<TTIOStorageProvider> _provider;
    id<TTIOStorageGroup> _group;
    NSString *_url;
}

- (id<TTIOStorageGroup>)group { return _group; }

static BOOL ttioCopyAttrs(id<TTIOStorageDataset> src, id<TTIOStorageDataset> dst, NSError **error)
{
    for (NSString *k in [src attributeNames]) {
        id v = [src attributeValueForName:k error:NULL];
        if (v != nil && ![dst setAttributeValue:v forName:k error:error]) return NO;
    }
    return YES;
}

static BOOL ttioWriteNames(id<TTIOStorageGroup> g, NSString *name, NSArray<NSString *> *names, NSError **error)
{
    NSArray *fields = @[[TTIOCompoundField fieldWithName:@"name" kind:TTIOCompoundFieldKindVLString]];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *n in names) [rows addObject:@{@"name": n}];
    id<TTIOStorageDataset> ds = [g createCompoundDatasetNamed:name fields:fields count:rows.count error:error];
    if (!ds) return NO;
    return [ds writeAll:rows error:error];
}

+ (NSArray<NSString *> *)readNamesIn:(id<TTIOStorageGroup>)group named:(NSString *)name
{
    NSMutableArray *out = [NSMutableArray array];
    if (![group hasChildNamed:name]) return out;
    id<TTIOStorageDataset> ds = [group openDatasetNamed:name error:NULL];
    NSArray *rows = [ds readRows:NULL];
    for (NSDictionary *row in rows) {
        id v = row[@"name"];
        if ([v isKindOfClass:[NSData class]]) {
            [out addObject:[[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] ?: @""];
        } else {
            [out addObject:v ? [v description] : @""];
        }
    }
    return out;
}

+ (instancetype)materialiseBlock:(NSUInteger)b
                           ofRun:(id<TTIOStorageGroup>)runGroup
                           table:(TTIOBlockTable *)t
                      chromNames:(NSArray<NSString *> *)chromNames
                  mateChromNames:(NSArray<NSString *> *)mateChromNames
                           error:(NSError **)error
{
    static _Atomic unsigned long counter = 0;
    unsigned long seq = atomic_fetch_add(&counter, 1);
    NSString *url = [NSString stringWithFormat:@"memory://ttio-block-view-%p-%lu-%lu",
                     (void *)runGroup, (unsigned long)b, seq];
    [TTIOMemoryProvider discardStore:url];
    id<TTIOStorageProvider> mem = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory" error:error];
    if (!mem) return nil;
    TTIOBlockView *v = [[TTIOBlockView alloc] init];
    v->_provider = mem;
    v->_url = url;
    id<TTIOStorageGroup> root = [mem rootGroupWithError:error];
    id<TTIOStorageGroup> view = [root createGroupNamed:@"run" error:error];
    if (!view) { [v discard]; return nil; }
    v->_group = view;

    NSSet *skipped = [NSSet setWithArray:@[@"layout", @"block_policy", @"base_count"]];
    for (NSString *k in [runGroup attributeNames]) {
        if ([skipped containsObject:k]) continue;
        id val = [runGroup attributeValueForName:k error:NULL];
        if (val != nil && ![view setAttributeValue:val forName:k error:error]) { [v discard]; return nil; }
    }
    unsigned long long r0 = [t readStartAt:b];
    NSUInteger n = [t nReadsAt:b];
    if (![view setAttributeValue:@((int64_t)n) forName:@"read_count" error:error]) { [v discard]; return nil; }

    id<TTIOStorageGroup> srcIdx = [runGroup openGroupNamed:@"genomic_index" error:error];
    id<TTIOStorageGroup> dstIdx = [view createGroupNamed:@"genomic_index" error:error];
    if (!srcIdx || !dstIdx) { [v discard]; return nil; }
    NSArray *arrays = @[
        @[@"lengths", @(TTIOPrecisionUInt32)],
        @[@"positions", @(TTIOPrecisionInt64)],
        @[@"mapping_qualities", @(TTIOPrecisionUInt8)],
        @[@"flags", @(TTIOPrecisionUInt32)],
        @[@"chromosome_ids", @(TTIOPrecisionUInt16)],
    ];
    for (NSArray *a in arrays) {
        id<TTIOStorageDataset> src = [srcIdx openDatasetNamed:a[0] error:error];
        if (!src) { [v discard]; return nil; }
        id arr = n > 0 ? [src readSliceAtOffset:(NSUInteger)r0 count:n error:error] : [NSData data];
        if (!arr) { [v discard]; return nil; }
        id<TTIOStorageDataset> dst = [dstIdx createDatasetNamed:a[0]
                                                      precision:(TTIOPrecision)[a[1] integerValue]
                                                         length:n
                                                      chunkSize:65536
                                                    compression:TTIOCompressionNone
                                               compressionLevel:0
                                                          error:error];
        if (!dst || ![dst writeAll:arr error:error]) { [v discard]; return nil; }
        if (!ttioCopyAttrs(src, dst, error)) { [v discard]; return nil; }
    }
    if (!ttioWriteNames(dstIdx, @"chromosome_names", chromNames, error)) { [v discard]; return nil; }

    id<TTIOStorageGroup> srcSc = [runGroup openGroupNamed:@"signal_channels" error:error];
    id<TTIOStorageGroup> dstSc = [view createGroupNamed:@"signal_channels" error:error];
    if (!srcSc || !dstSc) { [v discard]; return nil; }
    for (NSString *ch in [TTIOGenomicBlocks blockChannels]) {
        unsigned long long off = [t offsetOf:ch at:b], ln = [t lengthOf:ch at:b];
        if (ln == 0) continue;
        NSNumber *codec = t.hasCodecs ? @([t codecOf:ch at:b]) : nil;
        id<TTIOStorageDataset> src = nil;
        id<TTIOStorageGroup> dstParent = nil;
        NSString *dstName = nil;
        if ([ch isEqualToString:@"sequences"]) {
            src = [[srcSc openGroupNamed:@"sequences" error:error] openDatasetNamed:@"data" error:error];
            if (!src) { [v discard]; return nil; }
            if (codec == nil) codec = @([[src attributeValueForName:@"compression" error:NULL] unsignedIntegerValue]);
            if ([codec unsignedIntegerValue] == TTIOCompressionRefDiffV2) {
                dstParent = [dstSc createGroupNamed:@"sequences" error:error];
                dstName = @"refdiff_v2";
            } else {
                dstParent = dstSc;
                dstName = @"sequences";
            }
        } else if ([ch isEqualToString:@"mate_info"]) {
            src = [[srcSc openGroupNamed:@"mate_info" error:error] openDatasetNamed:@"inline_v2" error:error];
            dstParent = [dstSc createGroupNamed:@"mate_info" error:error];
            dstName = @"inline_v2";
        } else {
            src = [srcSc openDatasetNamed:ch error:error];
            dstParent = dstSc;
            dstName = ch;
        }
        if (!src || !dstParent) { [v discard]; return nil; }
        id blob = [src readSliceAtOffset:(NSUInteger)off count:(NSUInteger)ln error:error];
        if (!blob) { [v discard]; return nil; }
        id<TTIOStorageDataset> dst = [dstParent createDatasetNamed:dstName
                                                         precision:TTIOPrecisionUInt8
                                                            length:(NSUInteger)ln
                                                         chunkSize:65536
                                                       compression:TTIOCompressionNone
                                                  compressionLevel:0
                                                             error:error];
        if (!dst || ![dst writeAll:blob error:error]) { [v discard]; return nil; }
        if (!ttioCopyAttrs(src, dst, error)) { [v discard]; return nil; }
        if (codec != nil && ![dst setAttributeValue:@((int64_t)[codec unsignedIntegerValue])
                                          forName:@"compression" error:error]) { [v discard]; return nil; }
    }
    if ([srcSc hasChildNamed:@"mate_info"]) {
        id<TTIOStorageGroup> mate = [dstSc hasChildNamed:@"mate_info"]
            ? [dstSc openGroupNamed:@"mate_info" error:error]
            : [dstSc createGroupNamed:@"mate_info" error:error];
        if (!mate || !ttioWriteNames(mate, @"chrom_names", mateChromNames, error)) { [v discard]; return nil; }
    }
    return v;
}

- (void)discard
{
    _group = nil;
    if (_provider) { [_provider close]; _provider = nil; }
    if (_url) { [TTIOMemoryProvider discardStore:_url]; _url = nil; }
}

@end
