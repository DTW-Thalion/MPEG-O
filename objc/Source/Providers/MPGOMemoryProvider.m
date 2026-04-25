#import "MPGOMemoryProvider.h"
#import "MPGOProviderRegistry.h"
#import "MPGOCanonicalBytes.h"
#import "HDF5/MPGOHDF5Errors.h"

#pragma mark - Forward decls

@class MPGOMemGroup;
@class MPGOMemDataset;

// ──────────────────────────────────────────────────────────────
// MPGOMemGroup
// ──────────────────────────────────────────────────────────────

@interface MPGOMemGroup : NSObject <MPGOStorageGroup> {
    NSString *_name;
    NSMutableDictionary<NSString *, MPGOMemGroup *>   *_groups;
    NSMutableDictionary<NSString *, MPGOMemDataset *> *_datasets;
    NSMutableDictionary<NSString *, id>               *_attrs;
}
- (instancetype)initWithName:(NSString *)name;
@end

// ──────────────────────────────────────────────────────────────
// MPGOMemDataset
// ──────────────────────────────────────────────────────────────

@interface MPGOMemDataset : NSObject <MPGOStorageDataset> {
    NSString     *_name;
    MPGOPrecision _precision;
    NSArray<NSNumber *> *_shape;
    NSArray<NSNumber *> *_chunks;
    NSArray<MPGOCompoundField *> *_fields;
    id            _data;
    NSMutableDictionary<NSString *, id> *_attrs;
}
- (instancetype)initWithName:(NSString *)name
                    precision:(MPGOPrecision)precision
                        shape:(NSArray<NSNumber *> *)shape
                       chunks:(NSArray<NSNumber *> *)chunks
                       fields:(NSArray<MPGOCompoundField *> *)fields;
@end

#pragma mark - Group impl

@implementation MPGOMemGroup

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

- (id<MPGOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error
{
    MPGOMemGroup *g = _groups[name];
    if (!g && error) {
        *error = MPGOMakeError(MPGOErrorGroupOpen,
                @"no memory group '%@' under '%@'", name, _name);
    }
    return g;
}

- (id<MPGOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error
{
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    MPGOMemGroup *g = [[MPGOMemGroup alloc] initWithName:name];
    _groups[name] = g;
    return g;
}

- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error
{
    [_groups removeObjectForKey:name];
    [_datasets removeObjectForKey:name];
    return YES;
}

- (id<MPGOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    MPGOMemDataset *d = _datasets[name];
    if (!d && error) {
        *error = MPGOMakeError(MPGOErrorDatasetOpen,
                @"no memory dataset '%@' under '%@'", name, _name);
    }
    return d;
}

- (id<MPGOStorageDataset>)createDatasetNamed:(NSString *)name
                                     precision:(MPGOPrecision)precision
                                        length:(NSUInteger)length
                                     chunkSize:(NSUInteger)chunkSize
                                   compression:(MPGOCompression)compression
                              compressionLevel:(int)compressionLevel
                                         error:(NSError **)error
{
    (void)compression; (void)compressionLevel;
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    NSArray *shape = @[@(length)];
    NSArray *chunks = chunkSize > 0 ? @[@(chunkSize)] : nil;
    MPGOMemDataset *d = [[MPGOMemDataset alloc]
            initWithName:name precision:precision
                    shape:shape chunks:chunks fields:nil];
    _datasets[name] = d;
    return d;
}

- (id<MPGOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(MPGOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(MPGOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error
{
    (void)compression; (void)compressionLevel;
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    MPGOMemDataset *d = [[MPGOMemDataset alloc]
            initWithName:name precision:precision
                    shape:[shape copy]
                   chunks:[chunks copy]
                   fields:nil];
    _datasets[name] = d;
    return d;
}

- (id<MPGOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                 fields:(NSArray<MPGOCompoundField *> *)fields
                                                  count:(NSUInteger)count
                                                  error:(NSError **)error
{
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
                @"child '%@' already exists in '%@'", name, _name);
        return nil;
    }
    MPGOMemDataset *d = [[MPGOMemDataset alloc]
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
        *error = MPGOMakeError(MPGOErrorAttributeRead,
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

@implementation MPGOMemDataset

- (instancetype)initWithName:(NSString *)name
                    precision:(MPGOPrecision)precision
                        shape:(NSArray<NSNumber *> *)shape
                       chunks:(NSArray<NSNumber *> *)chunks
                       fields:(NSArray<MPGOCompoundField *> *)fields
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
- (MPGOPrecision)precision { return _precision; }
- (NSArray<NSNumber *> *)shape { return _shape; }
- (NSArray<NSNumber *> *)chunks { return _chunks; }
- (NSUInteger)length { return _shape.count > 0 ? [_shape[0] unsignedIntegerValue] : 0; }
- (NSArray<MPGOCompoundField *> *)compoundFields { return _fields; }

- (id)readAll:(NSError **)error { (void)error; return _data; }

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (_fields == nil) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"readRows: is only valid for compound datasets");
        return nil;
    }
    return (NSArray *)_data;
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    if (_fields != nil) {
        NSArray *rows = (NSArray *)_data;
        return [MPGOCanonicalBytes canonicalBytesForCompoundRows:rows
                                                            fields:_fields];
    }
    if (_data == nil) return [NSData data];
    if (![_data isKindOfClass:[NSData class]]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"MemDataset._data is not NSData");
        return nil;
    }
    return [MPGOCanonicalBytes canonicalBytesForNumericData:(NSData *)_data
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
        case MPGOPrecisionFloat32:   elem = 4;  break;
        case MPGOPrecisionFloat64:   elem = 8;  break;
        case MPGOPrecisionInt32:     elem = 4;  break;
        case MPGOPrecisionInt64:     elem = 8;  break;
        case MPGOPrecisionUInt32:    elem = 4;  break;
        case MPGOPrecisionComplex128:elem = 16; break;
        case MPGOPrecisionUInt8:     elem = 1;  break;
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
        *error = MPGOMakeError(MPGOErrorAttributeRead,
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

@implementation MPGOMemoryProvider {
    NSString *_url;
    MPGOMemGroup *_root;
    BOOL _open;
}

+ (void)load
{
    [[MPGOProviderRegistry sharedRegistry]
            registerProviderClass:self forName:@"memory"];
}

static NSMutableDictionary<NSString *, MPGOMemGroup *> *gStores(void)
{
    static NSMutableDictionary *d = nil;
    @synchronized ([MPGOMemoryProvider class]) {
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

- (BOOL)openURL:(NSString *)url mode:(MPGOStorageOpenMode)mode error:(NSError **)error
{
    NSString *key = normaliseURL(url);
    NSMutableDictionary *stores = gStores();
    @synchronized (stores) {
        switch (mode) {
            case MPGOStorageOpenModeCreate:
                stores[key] = [[MPGOMemGroup alloc] initWithName:@"/"];
                break;
            case MPGOStorageOpenModeRead:
                if (!stores[key]) {
                    if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
                            @"memory store '%@' not found", key);
                    return NO;
                }
                break;
            case MPGOStorageOpenModeReadWrite:
            case MPGOStorageOpenModeAppend:
                if (!stores[key]) {
                    stores[key] = [[MPGOMemGroup alloc] initWithName:@"/"];
                }
                break;
        }
        _url  = [key copy];
        _root = stores[key];
    }
    _open = YES;
    return YES;
}

- (id<MPGOStorageGroup>)rootGroupWithError:(NSError **)error { return _root; }
- (BOOL)isOpen { return _open; }
- (id)nativeHandle { return nil; }
- (void)close  { _open = NO; }

+ (void)discardStore:(NSString *)url
{
    @synchronized (gStores()) { [gStores() removeObjectForKey:normaliseURL(url)]; }
}

@end
