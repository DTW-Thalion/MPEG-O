#import "MPGOHDF5Provider.h"
#import "MPGOProviderRegistry.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "Dataset/MPGOCompoundIO.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import <hdf5.h>

#pragma mark - Adapters (forward decls)

@class MPGOHDF5GroupAdapter;
@class MPGOHDF5DatasetAdapter;
@class MPGOHDF5CompoundDatasetAdapter;

@interface MPGOHDF5CompoundDatasetAdapter : NSObject <MPGOStorageDataset>
- (instancetype)initWithParent:(MPGOHDF5Group *)parent
                           name:(NSString *)name
                         fields:(NSArray<MPGOCompoundField *> *)fields
                          count:(NSUInteger)count;
@end

// ──────────────────────────────────────────────────────────────
// Dataset adapter
// ──────────────────────────────────────────────────────────────

@interface MPGOHDF5DatasetAdapter : NSObject <MPGOStorageDataset>
- (instancetype)initWithDataset:(MPGOHDF5Dataset *)ds name:(NSString *)name;
@end

@implementation MPGOHDF5DatasetAdapter {
    MPGOHDF5Dataset *_ds;
    NSString *_name;
}

- (instancetype)initWithDataset:(MPGOHDF5Dataset *)ds name:(NSString *)name
{
    self = [super init];
    if (self) { _ds = ds; _name = [name copy]; }
    return self;
}

- (NSString *)name { return _name; }
- (MPGOPrecision)precision { return _ds.precision; }
- (NSUInteger)length { return _ds.length; }
- (NSArray<NSNumber *> *)shape { return @[@(_ds.length)]; }
- (NSArray<NSNumber *> *)chunks { return nil; }
- (NSArray<MPGOCompoundField *> *)compoundFields { return nil; }

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

- (BOOL)hasAttributeNamed:(NSString *)name { (void)name; return NO; }
- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    (void)name;
    if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"dataset-level attributes not exposed via MPGOHDF5Dataset");
    return nil;
}
- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    (void)value; (void)name;
    if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"dataset-level attributes not exposed via MPGOHDF5Dataset");
    return NO;
}

@end

// ──────────────────────────────────────────────────────────────
// Group adapter
// ──────────────────────────────────────────────────────────────

@interface MPGOHDF5GroupAdapter : NSObject <MPGOStorageGroup>
- (instancetype)initWithGroup:(MPGOHDF5Group *)group;
- (MPGOHDF5Group *)unwrap;
@end

@implementation MPGOHDF5GroupAdapter {
    MPGOHDF5Group *_group;
}

- (instancetype)initWithGroup:(MPGOHDF5Group *)group
{
    self = [super init];
    if (self) { _group = group; }
    return self;
}

- (MPGOHDF5Group *)unwrap { return _group; }

- (NSString *)name { return [_group groupName]; }
- (NSArray<NSString *> *)childNames { return [_group childNames]; }
- (BOOL)hasChildNamed:(NSString *)name { return [_group hasChildNamed:name]; }

- (id<MPGOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error
{
    MPGOHDF5Group *g = [_group openGroupNamed:name error:error];
    return g ? [[MPGOHDF5GroupAdapter alloc] initWithGroup:g] : nil;
}

- (id<MPGOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error
{
    MPGOHDF5Group *g = [_group createGroupNamed:name error:error];
    return g ? [[MPGOHDF5GroupAdapter alloc] initWithGroup:g] : nil;
}

- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error
{
    return [_group deleteChildNamed:name error:error];
}

- (id<MPGOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    MPGOHDF5Dataset *d = [_group openDatasetNamed:name error:error];
    return d ? [[MPGOHDF5DatasetAdapter alloc] initWithDataset:d name:name] : nil;
}

- (id<MPGOStorageDataset>)createDatasetNamed:(NSString *)name
                                     precision:(MPGOPrecision)precision
                                        length:(NSUInteger)length
                                     chunkSize:(NSUInteger)chunkSize
                                   compression:(MPGOCompression)compression
                              compressionLevel:(int)compressionLevel
                                         error:(NSError **)error
{
    MPGOHDF5Dataset *d = [_group createDatasetNamed:name
                                          precision:precision
                                             length:length
                                          chunkSize:chunkSize
                                        compression:compression
                                   compressionLevel:compressionLevel
                                              error:error];
    return d ? [[MPGOHDF5DatasetAdapter alloc] initWithDataset:d name:name] : nil;
}

- (id<MPGOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(MPGOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(MPGOCompression)compression
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
    if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"MPGOHDF5Provider does not yet implement N-D datasets "
            @"(shape=%@); use MPGOHDF5Group directly for image cubes",
            shape);
    return nil;
}

- (id<MPGOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                 fields:(NSArray<MPGOCompoundField *> *)fields
                                                  count:(NSUInteger)count
                                                  error:(NSError **)error
{
    // Compound dataset actually created on first writeAll: — expose a
    // lazy wrapper so length/compoundFields are queryable now.
    return [[MPGOHDF5CompoundDatasetAdapter alloc]
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
    if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
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
    if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
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

@implementation MPGOHDF5CompoundDatasetAdapter {
    MPGOHDF5Group *_parent;
    NSString *_name;
    NSArray<MPGOCompoundField *> *_fields;
    NSUInteger _count;
}

- (instancetype)initWithParent:(MPGOHDF5Group *)parent
                           name:(NSString *)name
                         fields:(NSArray<MPGOCompoundField *> *)fields
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
- (MPGOPrecision)precision { return 0; }
- (NSUInteger)length { return _count; }
- (NSArray<NSNumber *> *)shape { return @[@(_count)]; }
- (NSArray<NSNumber *> *)chunks { return nil; }
- (NSArray<MPGOCompoundField *> *)compoundFields { return _fields; }

- (id)readAll:(NSError **)error
{
    // Delegate to MPGOCompoundIO. At this level we only know the
    // schema the caller supplied on create; for pre-existing
    // datasets callers go through MPGOCompoundIO directly for now.
    return [MPGOCompoundIO readGenericFromGroup:_parent
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
    return [MPGOCompoundIO writeGeneric:(NSArray *)data
                               intoGroup:_parent
                            datasetNamed:_name
                                  fields:_fields
                                   error:error];
}

- (BOOL)hasAttributeNamed:(NSString *)name { (void)name; return NO; }
- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    (void)name;
    if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"compound-dataset attributes not yet routed");
    return nil;
}
- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    (void)value; (void)name;
    if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"compound-dataset attributes not yet routed");
    return NO;
}

@end

// ──────────────────────────────────────────────────────────────
// Provider
// ──────────────────────────────────────────────────────────────

@implementation MPGOHDF5Provider {
    MPGOHDF5File *_file;
    BOOL _open;
}

+ (void)load
{
    [[MPGOProviderRegistry sharedRegistry]
            registerProviderClass:self forName:@"hdf5"];
}

- (NSString *)providerName { return @"hdf5"; }

- (BOOL)supportsURL:(NSString *)url
{
    if ([url hasPrefix:@"memory://"]) return NO;
    return [url hasPrefix:@"file://"] || ![url containsString:@"://"];
}

- (BOOL)openURL:(NSString *)url mode:(MPGOStorageOpenMode)mode error:(NSError **)error
{
    NSString *path = [url hasPrefix:@"file://"]
            ? [url substringFromIndex:[@"file://" length]]
            : url;
    switch (mode) {
        case MPGOStorageOpenModeCreate:
            _file = [MPGOHDF5File createAtPath:path error:error]; break;
        case MPGOStorageOpenModeRead:
            _file = [MPGOHDF5File openReadOnlyAtPath:path error:error]; break;
        case MPGOStorageOpenModeReadWrite:
        case MPGOStorageOpenModeAppend:
            _file = [MPGOHDF5File openAtPath:path error:error]; break;
    }
    _open = (_file != nil);
    return _open;
}

- (id<MPGOStorageGroup>)rootGroupWithError:(NSError **)error
{
    if (!_file) {
        if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
                @"HDF5 provider not open");
        return nil;
    }
    MPGOHDF5Group *root = [_file rootGroup];
    return [[MPGOHDF5GroupAdapter alloc] initWithGroup:root];
}

- (BOOL)isOpen { return _open; }
- (id)nativeHandle { return _file; }
- (void)close { [_file close]; _open = NO; }

@end
