#import "TTIOGenomicIndex.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "HDF5/TTIOHDF5Types.h"  // TTIOPrecisionElementSize()
#import "HDF5/TTIOHDF5Group.h"
#import "Dataset/TTIOCompoundIO.h"

@implementation TTIOGenomicIndex {
    NSData *_offsetsData;
    NSData *_lengthsData;
    NSArray<NSString *> *_chromosomes;
    NSData *_positionsData;
    NSData *_mappingQualitiesData;
    NSData *_flagsData;
}

- (instancetype)initWithOffsets:(NSData *)offsets
                         lengths:(NSData *)lengths
                     chromosomes:(NSArray<NSString *> *)chromosomes
                       positions:(NSData *)positions
                mappingQualities:(NSData *)mappingQualities
                            flags:(NSData *)flags
{
    self = [super init];
    if (self) {
        _offsetsData          = [offsets copy];
        _lengthsData          = [lengths copy];
        _chromosomes          = [chromosomes copy];
        _positionsData        = [positions copy];
        _mappingQualitiesData = [mappingQualities copy];
        _flagsData            = [flags copy];
    }
    return self;
}

- (NSUInteger)count
{
    return _offsetsData.length / sizeof(uint64_t);
}

- (uint64_t)offsetAt:(NSUInteger)index
{
    return ((const uint64_t *)_offsetsData.bytes)[index];
}

- (uint32_t)lengthAt:(NSUInteger)index
{
    return ((const uint32_t *)_lengthsData.bytes)[index];
}

- (int64_t)positionAt:(NSUInteger)index
{
    return ((const int64_t *)_positionsData.bytes)[index];
}

- (uint8_t)mappingQualityAt:(NSUInteger)index
{
    return ((const uint8_t *)_mappingQualitiesData.bytes)[index];
}

- (uint32_t)flagsAt:(NSUInteger)index
{
    return ((const uint32_t *)_flagsData.bytes)[index];
}

- (NSString *)chromosomeAt:(NSUInteger)index
{
    return _chromosomes[index];
}

- (NSIndexSet *)indicesForRegion:(NSString *)chromosome
                            start:(int64_t)start
                              end:(int64_t)end
{
    NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
    NSUInteger n = self.count;
    const int64_t *positions = (const int64_t *)_positionsData.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        if ([_chromosomes[i] isEqualToString:chromosome]
            && positions[i] >= start
            && positions[i] < end) {
            [result addIndex:i];
        }
    }
    return result;
}

- (NSIndexSet *)indicesForUnmapped
{
    return [self indicesForFlag:0x4];
}

- (NSIndexSet *)indicesForFlag:(uint32_t)flagMask
{
    NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
    NSUInteger n = self.count;
    const uint32_t *flags = (const uint32_t *)_flagsData.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        if ((flags[i] & flagMask) != 0) {
            [result addIndex:i];
        }
    }
    return result;
}

// ── Disk I/O via the provider-agnostic StorageGroup protocol ───────

static BOOL writeTypedChannel(id<TTIOStorageGroup> g, NSString *name,
                              TTIOPrecision p, NSData *data, NSError **error)
{
    NSUInteger n = data.length / TTIOPrecisionElementSize(p);
    id<TTIOStorageDataset> ds = [g createDatasetNamed:name
                                             precision:p
                                                length:n
                                             chunkSize:65536
                                           compression:TTIOCompressionZlib
                                      compressionLevel:6
                                                 error:error];
    if (!ds) return NO;
    return [ds writeAll:data error:error];
}

static NSData *readTypedChannel(id<TTIOStorageGroup> g, NSString *name,
                                NSError **error)
{
    id<TTIOStorageDataset> ds = [g openDatasetNamed:name error:error];
    if (!ds) return nil;
    id val = [ds readAll:error];
    return [val isKindOfClass:[NSData class]] ? val : nil;
}

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    // 5 typed numeric channels, gzip+chunked.
    if (!writeTypedChannel(group, @"offsets",           TTIOPrecisionUInt64, _offsetsData,          error)) return NO;
    if (!writeTypedChannel(group, @"lengths",           TTIOPrecisionUInt32, _lengthsData,          error)) return NO;
    if (!writeTypedChannel(group, @"positions",         TTIOPrecisionInt64,  _positionsData,        error)) return NO;
    if (!writeTypedChannel(group, @"mapping_qualities", TTIOPrecisionUInt8,  _mappingQualitiesData, error)) return NO;
    if (!writeTypedChannel(group, @"flags",             TTIOPrecisionUInt32, _flagsData,            error)) return NO;

    // chromosomes — compound VL string with one field "value".
    // For HDF5 (group responds to `unwrap`), TTIOCompoundIO writes a
    // genuine HDF5 compound dataset that round-trips with Python's
    // write_compound_dataset output. For other providers (Memory etc.)
    // the storage-protocol compound API works because they bind fields
    // to the dataset at creation.
    NSArray *fields = @[[TTIOCompoundField fieldWithName:@"value"
                                                     kind:TTIOCompoundFieldKindVLString]];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:_chromosomes.count];
    for (NSString *c in _chromosomes) {
        [rows addObject:@{@"value": c}];
    }
    if ([group respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *h5 = [(id)group performSelector:@selector(unwrap)];
        return [TTIOCompoundIO writeGeneric:rows
                                   intoGroup:h5
                                datasetNamed:@"chromosomes"
                                      fields:fields
                                       error:error];
    }
    id<TTIOStorageDataset> ds = [group createCompoundDatasetNamed:@"chromosomes"
                                                            fields:fields
                                                             count:_chromosomes.count
                                                             error:error];
    if (!ds) return NO;
    return [ds writeAll:rows error:error];
}

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    NSError *cerr = nil;
    NSData *offsets   = readTypedChannel(group, @"offsets",           &cerr);
    if (!offsets)   { if (error) *error = cerr; return nil; }
    NSData *lengths   = readTypedChannel(group, @"lengths",           &cerr);
    if (!lengths)   { if (error) *error = cerr; return nil; }
    NSData *positions = readTypedChannel(group, @"positions",         &cerr);
    if (!positions) { if (error) *error = cerr; return nil; }
    NSData *mapqs     = readTypedChannel(group, @"mapping_qualities", &cerr);
    if (!mapqs)     { if (error) *error = cerr; return nil; }
    NSData *flags     = readTypedChannel(group, @"flags",             &cerr);
    if (!flags)     { if (error) *error = cerr; return nil; }

    NSArray<NSDictionary *> *chromRows = nil;
    if ([group respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *h5 = [(id)group performSelector:@selector(unwrap)];
        NSArray *fields = @[[TTIOCompoundField fieldWithName:@"value"
                                                         kind:TTIOCompoundFieldKindVLString]];
        chromRows = [TTIOCompoundIO readGenericFromGroup:h5
                                             datasetNamed:@"chromosomes"
                                                   fields:fields
                                                    error:&cerr];
    } else {
        id<TTIOStorageDataset> chromDs = [group openDatasetNamed:@"chromosomes" error:&cerr];
        if (chromDs) chromRows = [chromDs readAll:&cerr];
    }
    if (!chromRows) { if (error) *error = cerr; return nil; }
    if (![chromRows isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSString *> *chroms = [NSMutableArray arrayWithCapacity:chromRows.count];
    for (NSDictionary *row in chromRows) {
        id v = row[@"value"];
        if ([v isKindOfClass:[NSData class]]) {
            v = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
        }
        [chroms addObject:(NSString *)v ?: @""];
    }

    return [[TTIOGenomicIndex alloc]
        initWithOffsets:offsets
                lengths:lengths
            chromosomes:chroms
              positions:positions
       mappingQualities:mapqs
                  flags:flags];
}

@end
