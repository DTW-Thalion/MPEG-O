/*
 * TTIOMemoryProvider.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOMemoryProvider
 * Inherits From: NSObject
 * Conforms To:   TTIOStorageProvider, NSObject (NSObject)
 * Declared In:   Providers/TTIOMemoryProvider.h
 *
 * In-memory storage provider. Persists nothing; opens of the same
 * memory:// URL share a tree until +discardStore: is called. Useful
 * for tests, scratch work, and protocol-conformance verification
 * against TTIOHDF5Provider.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOMemoryProvider.h"
#import "TTIOProviderRegistry.h"
#import "TTIOCanonicalBytes.h"
#import "HDF5/TTIOHDF5Errors.h"

#pragma mark - Forward decls

@class TTIOMemGroup;
@class TTIOMemDataset;

// ──────────────────────────────────────────────────────────────
// TTIOMemGroup
// ──────────────────────────────────────────────────────────────

@interface TTIOMemGroup : NSObject <TTIOStorageGroup> {
    NSString *_name;
    NSMutableDictionary<NSString *, TTIOMemGroup *>   *_groups;
    NSMutableDictionary<NSString *, TTIOMemDataset *> *_datasets;
    NSMutableDictionary<NSString *, id>               *_attrs;
}
- (instancetype)initWithName:(NSString *)name;
@end

// ──────────────────────────────────────────────────────────────
// TTIOMemDataset
// ──────────────────────────────────────────────────────────────

@interface TTIOMemDataset : NSObject <TTIOStorageDataset> {
    NSString     *_name;
    TTIOPrecision _precision;
    NSArray<NSNumber *> *_shape;
    NSArray<NSNumber *> *_chunks;
    NSArray<TTIOCompoundField *> *_fields;
    id            _data;
    NSMutableDictionary<NSString *, id> *_attrs;
}
- (instancetype)initWithName:(NSString *)name
                    precision:(TTIOPrecision)precision
                        shape:(NSArray<NSNumber *> *)shape
                       chunks:(NSArray<NSNumber *> *)chunks
                       fields:(NSArray<TTIOCompoundField *> *)fields;
@end

#pragma mark - Group impl

@implementation TTIOMemGroup

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (self) {
        _name     = [name copy];
        _groups   = [NSMutableDictionary dictionary];
        _datasets = [NSMutableDictionary dictionary];
        _attrs    = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)name { return _name; }

- (NSArray<NSString *> *)childNames
{
    NSMutableArray *out = [NSMutableArray arrayWithArray:_groups.allKeys];
    [out addObjectsFromArray:_datasets.allKeys];
    return out;
}

- (BOOL)hasChildNamed:(NSString *)name
{
    return _groups[name] != nil || _datasets[name] != nil;
}

- (id<TTIOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error
{
    TTIOMemGroup *g = _groups[name];
    if (!g && error) {
        *error = TTIOMakeError(TTIOErrorGroupOpen,
                @"no memory group '%@' under '%@'", name, _name);
    }
    return g;
}

- (id<TTIOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error
{
    if ([self hasChildNamed:name]) {
        if (error) *error = TTIOMakeError(TTIOErrorGroupCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    TTIOMemGroup *g = [[TTIOMemGroup alloc] initWithName:name];
    _groups[name] = g;
    return g;
}

- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error
{
    [_groups removeObjectForKey:name];
    [_datasets removeObjectForKey:name];
    return YES;
}

- (id<TTIOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    TTIOMemDataset *d = _datasets[name];
    if (!d && error) {
        *error = TTIOMakeError(TTIOErrorDatasetOpen,
                @"no memory dataset '%@' under '%@'", name, _name);
    }
    return d;
}

- (id<TTIOStorageDataset>)createDatasetNamed:(NSString *)name
                                     precision:(TTIOPrecision)precision
                                        length:(NSUInteger)length
                                     chunkSize:(NSUInteger)chunkSize
                                   compression:(TTIOCompression)compression
                              compressionLevel:(int)compressionLevel
                                         error:(NSError **)error
{
    (void)compression; (void)compressionLevel;
    if ([self hasChildNamed:name]) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    NSArray *shape = @[@(length)];
    NSArray *chunks = chunkSize > 0 ? @[@(chunkSize)] : nil;
    TTIOMemDataset *d = [[TTIOMemDataset alloc]
            initWithName:name precision:precision
                    shape:shape chunks:chunks fields:nil];
    _datasets[name] = d;
    return d;
}

- (id<TTIOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(TTIOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(TTIOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error
{
    (void)compression; (void)compressionLevel;
    if ([self hasChildNamed:name]) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    TTIOMemDataset *d = [[TTIOMemDataset alloc]
            initWithName:name precision:precision
                    shape:[shape copy]
                   chunks:[chunks copy]
                   fields:nil];
    _datasets[name] = d;
    return d;
}

- (id<TTIOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                 fields:(NSArray<TTIOCompoundField *> *)fields
                                                  count:(NSUInteger)count
                                                  error:(NSError **)error
{
    if ([self hasChildNamed:name]) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    TTIOMemDataset *d = [[TTIOMemDataset alloc]
            initWithName:name precision:0
                    shape:@[@(count)] chunks:nil fields:[fields copy]];
    _datasets[name] = d;
    return d;
}

- (BOOL)hasAttributeNamed:(NSString *)name { return _attrs[name] != nil; }

- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    id v = _attrs[name];
    if (!v && error) {
        *error = TTIOMakeError(TTIOErrorAttributeRead,
                @"no attribute '%@' on group '%@'", name, _name);
    }
    return v;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    if (value == nil) {
        [_attrs removeObjectForKey:name];
    } else {
        _attrs[name] = value;
    }
    return YES;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    [_attrs removeObjectForKey:name];
    return YES;
}

- (NSArray<NSString *> *)attributeNames { return _attrs.allKeys; }

@end

#pragma mark - Dataset impl

@implementation TTIOMemDataset

- (instancetype)initWithName:(NSString *)name
                    precision:(TTIOPrecision)precision
                        shape:(NSArray<NSNumber *> *)shape
                       chunks:(NSArray<NSNumber *> *)chunks
                       fields:(NSArray<TTIOCompoundField *> *)fields
{
    self = [super init];
    if (self) {
        _name      = [name copy];
        _precision = precision;
        _shape     = [shape copy];
        _chunks    = [chunks copy];
        _fields    = [fields copy];
        _attrs     = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)name { return _name; }
- (TTIOPrecision)precision { return _precision; }
- (NSArray<NSNumber *> *)shape { return _shape; }
- (NSArray<NSNumber *> *)chunks { return _chunks; }
- (NSUInteger)length { return _shape.count > 0 ? [_shape[0] unsignedIntegerValue] : 0; }
- (NSArray<TTIOCompoundField *> *)compoundFields { return _fields; }

- (id)readAll:(NSError **)error { (void)error; return _data; }

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (_fields == nil) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"readRows: is only valid for compound datasets");
        return nil;
    }
    return (NSArray *)_data;
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    if (_fields != nil) {
        NSArray *rows = (NSArray *)_data;
        return [TTIOCanonicalBytes canonicalBytesForCompoundRows:rows
                                                            fields:_fields];
    }
    if (_data == nil) return [NSData data];
    if (![_data isKindOfClass:[NSData class]]) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"MemDataset._data is not NSData");
        return nil;
    }
    return [TTIOCanonicalBytes canonicalBytesForNumericData:(NSData *)_data
                                                   precision:_precision];
}

- (id)readSliceAtOffset:(NSUInteger)offset count:(NSUInteger)count error:(NSError **)error
{
    if (_fields) {
        NSArray *all = (NSArray *)_data;
        NSUInteger from = MIN(offset, all.count);
        NSUInteger to   = MIN(from + count, all.count);
        return [all subarrayWithRange:NSMakeRange(from, to - from)];
    }
    NSData *full = (NSData *)_data;
    if (!full) return nil;
    NSUInteger elem;
    switch (_precision) {
        case TTIOPrecisionFloat32:   elem = 4;  break;
        case TTIOPrecisionFloat64:   elem = 8;  break;
        case TTIOPrecisionInt32:     elem = 4;  break;
        case TTIOPrecisionInt64:     elem = 8;  break;
        case TTIOPrecisionUInt32:    elem = 4;  break;
        case TTIOPrecisionComplex128:elem = 16; break;
        case TTIOPrecisionUInt8:     elem = 1;  break;
        case TTIOPrecisionUInt16:    elem = 2;  break;  // L1
        case TTIOPrecisionUInt64:    elem = 8;  break;
        default:                     elem = 8;  break;
    }
    NSUInteger start = offset * elem;
    NSUInteger len   = count * elem;
    if (start + len > full.length) len = full.length - start;
    return [full subdataWithRange:NSMakeRange(start, len)];
}

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    _data = [data copy];
    return YES;
}

- (BOOL)hasAttributeNamed:(NSString *)name { return _attrs[name] != nil; }

- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    id v = _attrs[name];
    if (!v && error) {
        *error = TTIOMakeError(TTIOErrorAttributeRead,
                @"no attribute '%@' on dataset '%@'", name, _name);
    }
    return v;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    (void)error;
    if (value == nil) [_attrs removeObjectForKey:name];
    else              _attrs[name] = value;
    return YES;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    (void)error;
    [_attrs removeObjectForKey:name];
    return YES;
}

- (NSArray<NSString *> *)attributeNames { return _attrs.allKeys; }

@end

#pragma mark - Provider impl

@implementation TTIOMemoryProvider {
    NSString *_url;
    TTIOMemGroup *_root;
    BOOL _open;
}

+ (void)load
{
    [[TTIOProviderRegistry sharedRegistry]
            registerProviderClass:self forName:@"memory"];
}

static NSMutableDictionary<NSString *, TTIOMemGroup *> *gStores(void)
{
    static NSMutableDictionary *d = nil;
    @synchronized ([TTIOMemoryProvider class]) {
        if (!d) d = [NSMutableDictionary dictionary];
    }
    return d;
}

static NSString *normaliseURL(NSString *url)
{
    if ([url hasPrefix:@"memory://"]) return url;
    return [@"memory://" stringByAppendingString:url];
}

- (NSString *)providerName { return @"memory"; }

- (BOOL)supportsURL:(NSString *)url { return [url hasPrefix:@"memory://"]; }

- (BOOL)openURL:(NSString *)url mode:(TTIOStorageOpenMode)mode error:(NSError **)error
{
    NSString *key = normaliseURL(url);
    NSMutableDictionary *stores = gStores();
    @synchronized (stores) {
        switch (mode) {
            case TTIOStorageOpenModeCreate:
                stores[key] = [[TTIOMemGroup alloc] initWithName:@"/"];
                break;
            case TTIOStorageOpenModeRead:
                if (!stores[key]) {
                    if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
                            @"memory store '%@' not found", key);
                    return NO;
                }
                break;
            case TTIOStorageOpenModeReadWrite:
            case TTIOStorageOpenModeAppend:
                if (!stores[key]) {
                    stores[key] = [[TTIOMemGroup alloc] initWithName:@"/"];
                }
                break;
        }
        _url  = [key copy];
        _root = stores[key];
    }
    _open = YES;
    return YES;
}

- (id<TTIOStorageGroup>)rootGroupWithError:(NSError **)error { return _root; }
- (BOOL)isOpen { return _open; }
- (id)nativeHandle { return nil; }
- (void)close  { _open = NO; }

+ (void)discardStore:(NSString *)url
{
    @synchronized (gStores()) { [gStores() removeObjectForKey:normaliseURL(url)]; }
}

@end
