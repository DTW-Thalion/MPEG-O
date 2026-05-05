/*
 * TTIOHDF5Provider.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOHDF5Provider
 * Inherits From: NSObject
 * Conforms To:   TTIOStorageProvider, NSObject (NSObject)
 * Declared In:   Providers/TTIOHDF5Provider.h
 *
 * HDF5 storage provider. Adapter over the existing
 * TTIOHDF5File / Group / Dataset layer; registers for both file://
 * and bare-path URLs. Surfaces the underlying TTIOHDF5File via
 * -nativeHandle for byte-level callers (signatures, encryption).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOHDF5Provider.h"
#import "TTIOProviderRegistry.h"
#import "TTIOCanonicalBytes.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "Dataset/TTIOCompoundIO.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import <hdf5.h>

#pragma mark - Adapters (forward decls)

@class TTIOHDF5GroupAdapter;
@class TTIOHDF5DatasetAdapter;
@class TTIOHDF5CompoundDatasetAdapter;

@interface TTIOHDF5CompoundDatasetAdapter : NSObject <TTIOStorageDataset>
- (instancetype)initWithParent:(TTIOHDF5Group *)parent
                           name:(NSString *)name
                         fields:(NSArray<TTIOCompoundField *> *)fields
                          count:(NSUInteger)count;
@end

// ──────────────────────────────────────────────────────────────
// Dataset adapter
// ──────────────────────────────────────────────────────────────

@interface TTIOHDF5DatasetAdapter : NSObject <TTIOStorageDataset>
- (instancetype)initWithDataset:(TTIOHDF5Dataset *)ds name:(NSString *)name;
/** v0.7 M45: reconstructed rank for flattened N-D datasets. nil for
 *  genuine 1-D datasets. Set by the group adapter on create / open. */
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *ndShape;
@end

@implementation TTIOHDF5DatasetAdapter {
    TTIOHDF5Dataset *_ds;
    NSString *_name;
}

@synthesize ndShape = _ndShape;

- (instancetype)initWithDataset:(TTIOHDF5Dataset *)ds name:(NSString *)name
{
    self = [super init];
    if (self) { _ds = ds; _name = [name copy]; }
    return self;
}

- (NSString *)name { return _name; }
- (TTIOPrecision)precision { return _ds.precision; }
- (NSUInteger)length {
    // Axis-0 size for N-D datasets, element count for 1-D.
    if (_ndShape.count > 0) return [_ndShape[0] unsignedIntegerValue];
    return _ds.length;
}
- (NSArray<NSNumber *> *)shape {
    if (_ndShape) return _ndShape;
    return @[@(_ds.length)];
}
- (NSArray<NSNumber *> *)chunks { return nil; }
- (NSArray<TTIOCompoundField *> *)compoundFields { return nil; }

- (id)readAll:(NSError **)error
{
    return [_ds readDataWithError:error];
}

- (id)readSliceAtOffset:(NSUInteger)offset count:(NSUInteger)count error:(NSError **)error
{
    return [_ds readDataAtOffset:offset count:count error:error];
}

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    return [_ds writeData:(NSData *)data error:error];
}

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
        @"readRows: is only valid for compound datasets");
    return nil;
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    NSData *raw = [_ds readDataWithError:error];
    if (!raw) return nil;
    return [TTIOCanonicalBytes canonicalBytesForNumericData:raw
                                                   precision:_ds.precision];
}

- (BOOL)hasAttributeNamed:(NSString *)name { (void)name; return NO; }
- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"dataset-level attributes not exposed via TTIOHDF5Dataset");
    return nil;
}
- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    (void)value; (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"dataset-level attributes not exposed via TTIOHDF5Dataset");
    return NO;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"dataset-level attributes not exposed via TTIOHDF5Dataset");
    return NO;
}

- (NSArray<NSString *> *)attributeNames { return @[]; }

@end

// ──────────────────────────────────────────────────────────────
// Group adapter
// ──────────────────────────────────────────────────────────────

@interface TTIOHDF5GroupAdapter : NSObject <TTIOStorageGroup>
- (instancetype)initWithGroup:(TTIOHDF5Group *)group;
- (TTIOHDF5Group *)unwrap;
@end

@implementation TTIOHDF5GroupAdapter {
    TTIOHDF5Group *_group;
}

- (instancetype)initWithGroup:(TTIOHDF5Group *)group
{
    self = [super init];
    if (self) { _group = group; }
    return self;
}

- (TTIOHDF5Group *)unwrap { return _group; }

- (NSString *)name { return [_group groupName]; }
- (NSArray<NSString *> *)childNames { return [_group childNames]; }
- (BOOL)hasChildNamed:(NSString *)name { return [_group hasChildNamed:name]; }

- (id<TTIOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error
{
    TTIOHDF5Group *g = [_group openGroupNamed:name error:error];
    return g ? [[TTIOHDF5GroupAdapter alloc] initWithGroup:g] : nil;
}

- (id<TTIOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error
{
    TTIOHDF5Group *g = [_group createGroupNamed:name error:error];
    return g ? [[TTIOHDF5GroupAdapter alloc] initWithGroup:g] : nil;
}

- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error
{
    return [_group deleteChildNamed:name error:error];
}

- (id<TTIOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    TTIOHDF5Dataset *d = [_group openDatasetNamed:name error:error];
    if (!d) return nil;
    TTIOHDF5DatasetAdapter *adapter =
        [[TTIOHDF5DatasetAdapter alloc] initWithDataset:d name:name];

    // v0.7 M45: if the parent group carries @__shape_<name>__, this
    // is a flattened N-D dataset. Parse the JSON-ish shape string and
    // attach to the adapter so shape() reports the full rank.
    NSString *shapeAttr = [NSString stringWithFormat:@"__shape_%@__", name];
    if ([_group hasAttributeNamed:shapeAttr]) {
        NSString *s = [_group stringAttributeNamed:shapeAttr error:NULL];
        if (s) {
            NSString *inner = [s stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([inner hasPrefix:@"["]) inner = [inner substringFromIndex:1];
            if ([inner hasSuffix:@"]"]) {
                inner = [inner substringToIndex:inner.length - 1];
            }
            if (inner.length > 0) {
                NSArray<NSString *> *parts = [inner componentsSeparatedByString:@","];
                NSMutableArray<NSNumber *> *nd = [NSMutableArray arrayWithCapacity:parts.count];
                for (NSString *p in parts) {
                    [nd addObject:@([[p stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]]
                        longLongValue])];
                }
                adapter.ndShape = nd;
            }
        }
    }
    return adapter;
}

- (id<TTIOStorageDataset>)createDatasetNamed:(NSString *)name
                                     precision:(TTIOPrecision)precision
                                        length:(NSUInteger)length
                                     chunkSize:(NSUInteger)chunkSize
                                   compression:(TTIOCompression)compression
                              compressionLevel:(int)compressionLevel
                                         error:(NSError **)error
{
    TTIOHDF5Dataset *d = [_group createDatasetNamed:name
                                          precision:precision
                                             length:length
                                          chunkSize:chunkSize
                                        compression:compression
                                   compressionLevel:compressionLevel
                                              error:error];
    return d ? [[TTIOHDF5DatasetAdapter alloc] initWithDataset:d name:name] : nil;
}

- (id<TTIOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(TTIOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(TTIOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error
{
    if (shape.count == 1) {
        NSUInteger chunkSize = chunks.count > 0 ? [chunks[0] unsignedIntegerValue] : 0;
        return [self createDatasetNamed:name
                               precision:precision
                                  length:[shape[0] unsignedIntegerValue]
                               chunkSize:chunkSize
                             compression:compression
                        compressionLevel:compressionLevel
                                   error:error];
    }

    // v0.7 M45: rank ≥ 2. Stored as a flat 1-D HDF5 dataset plus a
    // @__shape_<name>__ attribute on the parent group recording the
    // original rank and dims. Matches SqliteProvider's layout so
    // canonical bytes stay bit-identical across backends; native
    // H5Screate_simple(rank, dims, null) storage is a v0.8
    // optimisation (M44 MSImage refactor scope).
    NSUInteger total = 1;
    for (NSNumber *n in shape) total *= [n unsignedIntegerValue];

    NSUInteger chunkSize = 0;
    if (chunks.count > 0) {
        NSUInteger chunkTotal = 1;
        for (NSNumber *c in chunks) chunkTotal *= [c unsignedIntegerValue];
        chunkSize = MIN(chunkTotal, total);
    }

    TTIOHDF5Dataset *ds =
        [_group createDatasetNamed:name
                          precision:precision
                             length:total
                          chunkSize:chunkSize
                        compression:compression
                   compressionLevel:compressionLevel
                              error:error];
    if (!ds) return nil;

    NSMutableString *sb = [NSMutableString stringWithString:@"["];
    for (NSUInteger i = 0; i < shape.count; i++) {
        if (i > 0) [sb appendString:@","];
        [sb appendFormat:@"%lu", (unsigned long)[shape[i] unsignedIntegerValue]];
    }
    [sb appendString:@"]"];

    NSString *shapeAttr = [NSString stringWithFormat:@"__shape_%@__", name];
    [_group setStringAttribute:shapeAttr value:sb error:error];

    TTIOHDF5DatasetAdapter *adapter =
        [[TTIOHDF5DatasetAdapter alloc] initWithDataset:ds
                                                    name:name];
    adapter.ndShape = shape;
    return adapter;
}

- (id<TTIOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                 fields:(NSArray<TTIOCompoundField *> *)fields
                                                  count:(NSUInteger)count
                                                  error:(NSError **)error
{
    // Compound dataset actually created on first writeAll: — expose a
    // lazy wrapper so length/compoundFields are queryable now.
    return [[TTIOHDF5CompoundDatasetAdapter alloc]
            initWithParent:_group name:name fields:fields count:count];
}

- (BOOL)hasAttributeNamed:(NSString *)name { return [_group hasAttributeNamed:name]; }

- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    // Try string first, then integer.
    NSError *inner = nil;
    NSString *s = [_group stringAttributeNamed:name error:&inner];
    if (s) return s;
    BOOL exists = NO;
    int64_t v = [_group integerAttributeNamed:name exists:&exists error:NULL];
    if (exists) return @(v);
    if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"attribute '%@' not found", name);
    return nil;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    if ([value isKindOfClass:[NSString class]]) {
        return [_group setStringAttribute:name value:(NSString *)value error:error];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [_group setIntegerAttribute:name
                                      value:[(NSNumber *)value longLongValue]
                                      error:error];
    }
    if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"attribute '%@' value type %@ not supported",
            name, [value class]);
    return NO;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    return [_group deleteAttributeNamed:name error:error];
}

- (NSArray<NSString *> *)attributeNames { return [_group attributeNames]; }

@end

// ──────────────────────────────────────────────────────────────
// Lazy compound dataset adapter
// ──────────────────────────────────────────────────────────────

@implementation TTIOHDF5CompoundDatasetAdapter {
    TTIOHDF5Group *_parent;
    NSString *_name;
    NSArray<TTIOCompoundField *> *_fields;
    NSUInteger _count;
}

- (instancetype)initWithParent:(TTIOHDF5Group *)parent
                           name:(NSString *)name
                         fields:(NSArray<TTIOCompoundField *> *)fields
                          count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _parent = parent;
        _name   = [name copy];
        _fields = [fields copy];
        _count  = count;
    }
    return self;
}

- (NSString *)name { return _name; }
- (TTIOPrecision)precision { return 0; }
- (NSUInteger)length { return _count; }
- (NSArray<NSNumber *> *)shape { return @[@(_count)]; }
- (NSArray<NSNumber *> *)chunks { return nil; }
- (NSArray<TTIOCompoundField *> *)compoundFields { return _fields; }

- (id)readAll:(NSError **)error
{
    // Delegate to TTIOCompoundIO. At this level we only know the
    // schema the caller supplied on create; for pre-existing
    // datasets callers go through TTIOCompoundIO directly for now.
    return [TTIOCompoundIO readGenericFromGroup:_parent
                                    datasetNamed:_name
                                          fields:_fields
                                           error:error];
}

- (id)readSliceAtOffset:(NSUInteger)offset count:(NSUInteger)count error:(NSError **)error
{
    NSArray *all = [self readAll:error];
    if (!all) return nil;
    NSUInteger from = MIN(offset, all.count);
    NSUInteger to   = MIN(from + count, all.count);
    return [all subarrayWithRange:NSMakeRange(from, to - from)];
}

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    return [TTIOCompoundIO writeGeneric:(NSArray *)data
                               intoGroup:_parent
                            datasetNamed:_name
                                  fields:_fields
                                   error:error];
}

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    return [self readAll:error];
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    NSArray<NSDictionary<NSString *, id> *> *rows = [self readRows:error];
    if (!rows) return nil;
    return [TTIOCanonicalBytes canonicalBytesForCompoundRows:rows
                                                       fields:_fields];
}

- (BOOL)hasAttributeNamed:(NSString *)name { (void)name; return NO; }
- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"compound-dataset attributes not yet routed");
    return nil;
}
- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    (void)value; (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"compound-dataset attributes not yet routed");
    return NO;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    (void)name;
    if (error) *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"compound-dataset attributes not yet routed");
    return NO;
}

- (NSArray<NSString *> *)attributeNames { return @[]; }

@end

// ──────────────────────────────────────────────────────────────
// Provider
// ──────────────────────────────────────────────────────────────

@implementation TTIOHDF5Provider {
    TTIOHDF5File *_file;
    BOOL _open;
}

+ (void)load
{
    [[TTIOProviderRegistry sharedRegistry]
            registerProviderClass:self forName:@"hdf5"];
}

- (NSString *)providerName { return @"hdf5"; }

- (BOOL)supportsURL:(NSString *)url
{
    if ([url hasPrefix:@"memory://"]) return NO;
    return [url hasPrefix:@"file://"] || ![url containsString:@"://"];
}

- (BOOL)openURL:(NSString *)url mode:(TTIOStorageOpenMode)mode error:(NSError **)error
{
    NSString *path = [url hasPrefix:@"file://"]
            ? [url substringFromIndex:[@"file://" length]]
            : url;
    switch (mode) {
        case TTIOStorageOpenModeCreate:
            _file = [TTIOHDF5File createAtPath:path error:error]; break;
        case TTIOStorageOpenModeRead:
            _file = [TTIOHDF5File openReadOnlyAtPath:path error:error]; break;
        case TTIOStorageOpenModeReadWrite:
        case TTIOStorageOpenModeAppend:
            _file = [TTIOHDF5File openAtPath:path error:error]; break;
    }
    _open = (_file != nil);
    return _open;
}

- (id<TTIOStorageGroup>)rootGroupWithError:(NSError **)error
{
    if (!_file) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
                @"HDF5 provider not open");
        return nil;
    }
    TTIOHDF5Group *root = [_file rootGroup];
    return [[TTIOHDF5GroupAdapter alloc] initWithGroup:root];
}

- (BOOL)isOpen { return _open; }
- (id)nativeHandle { return _file; }
- (void)close { [_file close]; _open = NO; }

- (BOOL)supportsChunking    { return YES; }
- (BOOL)supportsCompression { return YES; }

// ── v0.7 M44: factory wrappers (expose internal adapters) ───────────

+ (id<TTIOStorageGroup>)adapterForGroup:(TTIOHDF5Group *)group
{
    return [[TTIOHDF5GroupAdapter alloc] initWithGroup:group];
}

+ (id<TTIOStorageDataset>)adapterForDataset:(TTIOHDF5Dataset *)dataset
                                         name:(NSString *)name
{
    return [[TTIOHDF5DatasetAdapter alloc] initWithDataset:dataset name:name];
}

+ (id<TTIOStorageDataset>)adapterForCompoundDatasetWithParent:(TTIOHDF5Group *)parent
                                                          name:(NSString *)name
                                                        fields:(NSArray<TTIOCompoundField *> *)fields
                                                         count:(NSUInteger)count
{
    return [[TTIOHDF5CompoundDatasetAdapter alloc]
            initWithParent:parent name:name fields:fields count:count];
}

@end
