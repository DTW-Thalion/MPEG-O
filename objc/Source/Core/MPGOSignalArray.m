#import "MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOSignalArray
{
    NSMutableArray<MPGOCVParam *> *_cvParams;
}

- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(MPGOEncodingSpec *)encoding
                          axis:(MPGOAxisDescriptor *)axis
{
    NSParameterAssert(buffer != nil);
    NSParameterAssert(encoding != nil);
    NSParameterAssert(buffer.length == length * [encoding elementSize]);

    self = [super init];
    if (self) {
        _buffer   = [buffer copy];
        _length   = length;
        _encoding = encoding;
        _axis     = axis;
        _cvParams = [NSMutableArray array];
    }
    return self;
}

#pragma mark - HDF5

- (BOOL)writeToGroup:(MPGOHDF5Group *)group
                name:(NSString *)name
           chunkSize:(NSUInteger)chunkSize
    compressionLevel:(int)compressionLevel
               error:(NSError **)error
{
    MPGOHDF5Group *sub = [group createGroupNamed:name error:error];
    if (!sub) return NO;

    MPGOHDF5Dataset *ds =
        [sub createDatasetNamed:@"buffer"
                      precision:_encoding.precision
                         length:_length
                      chunkSize:chunkSize
               compressionLevel:compressionLevel
                          error:error];
    if (!ds) return NO;
    if (![ds writeData:_buffer error:error]) return NO;

    if (![sub setIntegerAttribute:@"compression"
                            value:(int64_t)_encoding.compressionAlgorithm
                            error:error]) return NO;
    if (![sub setIntegerAttribute:@"byte_order"
                            value:(int64_t)_encoding.byteOrder
                            error:error]) return NO;
    if (![sub setIntegerAttribute:@"precision"
                            value:(int64_t)_encoding.precision
                            error:error]) return NO;

    if (_axis) {
        if (![sub setStringAttribute:@"axis_name"  value:_axis.name  error:error]) return NO;
        if (![sub setStringAttribute:@"axis_unit"  value:_axis.unit  error:error]) return NO;
        if (![sub setIntegerAttribute:@"axis_sampling_mode"
                                value:(int64_t)_axis.samplingMode error:error]) return NO;
        // Encode range as two doubles via a dataset to keep the attribute API simple.
        MPGOHDF5Dataset *rng = [sub createDatasetNamed:@"axis_range"
                                             precision:MPGOPrecisionFloat64
                                                length:2
                                             chunkSize:0
                                      compressionLevel:0
                                                 error:error];
        if (!rng) return NO;
        double r[2] = { _axis.valueRange.minimum, _axis.valueRange.maximum };
        NSData *rdata = [NSData dataWithBytes:r length:sizeof(r)];
        if (![rng writeData:rdata error:error]) return NO;
    }

    if (_cvParams.count > 0) {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:_cvParams.count];
        for (MPGOCVParam *p in _cvParams) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"ontologyRef"] = p.ontologyRef;
            d[@"accession"]   = p.accession;
            d[@"name"]        = p.name;
            if (p.value) d[@"value"] = [p.value description];
            if (p.unit)  d[@"unit"]  = p.unit;
            [items addObject:d];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:items
                                                       options:0
                                                         error:error];
        if (!json) return NO;
        NSString *jsonStr = [[NSString alloc] initWithData:json
                                                  encoding:NSUTF8StringEncoding];
        if (![sub setStringAttribute:@"cv_params" value:jsonStr error:error]) return NO;
    }

    return YES;
}

+ (instancetype)readFromGroup:(MPGOHDF5Group *)group
                         name:(NSString *)name
                        error:(NSError **)error
{
    MPGOHDF5Group *sub = [group openGroupNamed:name error:error];
    if (!sub) return nil;

    MPGOHDF5Dataset *ds = [sub openDatasetNamed:@"buffer" error:error];
    if (!ds) return nil;

    NSData *bytes = [ds readDataWithError:error];
    if (!bytes) return nil;

    BOOL exists = NO;
    int64_t comp = [sub integerAttributeNamed:@"compression" exists:&exists error:error];
    if (!exists) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"signal array missing 'compression' attribute");
        return nil;
    }
    int64_t byte = [sub integerAttributeNamed:@"byte_order" exists:&exists error:error];
    if (!exists) return nil;

    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:ds.precision
                       compressionAlgorithm:(MPGOCompression)comp
                                  byteOrder:(MPGOByteOrder)byte];

    MPGOAxisDescriptor *axis = nil;
    if ([sub hasAttributeNamed:@"axis_name"]) {
        NSString *axName = [sub stringAttributeNamed:@"axis_name" error:error];
        NSString *axUnit = [sub stringAttributeNamed:@"axis_unit" error:error];
        int64_t  axMode  = [sub integerAttributeNamed:@"axis_sampling_mode"
                                               exists:&exists error:error];
        MPGOHDF5Dataset *rng = [sub openDatasetNamed:@"axis_range" error:error];
        if (!rng) return nil;
        NSData *rdata = [rng readDataWithError:error];
        if (!rdata || rdata.length < 2 * sizeof(double)) return nil;
        const double *rp = rdata.bytes;
        MPGOValueRange *vr = [MPGOValueRange rangeWithMinimum:rp[0] maximum:rp[1]];
        axis = [MPGOAxisDescriptor descriptorWithName:axName
                                                 unit:axUnit
                                           valueRange:vr
                                         samplingMode:(MPGOSamplingMode)axMode];
    }

    MPGOSignalArray *arr = [[self alloc] initWithBuffer:bytes
                                                 length:ds.length
                                               encoding:enc
                                                   axis:axis];

    if ([sub hasAttributeNamed:@"cv_params"]) {
        NSString *json = [sub stringAttributeNamed:@"cv_params" error:error];
        NSData *jdata = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *items = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:error];
        for (NSDictionary *d in items) {
            MPGOCVParam *p =
                [MPGOCVParam paramWithOntologyRef:d[@"ontologyRef"]
                                        accession:d[@"accession"]
                                             name:d[@"name"]
                                            value:d[@"value"]
                                             unit:d[@"unit"]];
            [arr addCVParam:p];
        }
    }

    return arr;
}

#pragma mark - MPGOCVAnnotatable

- (void)addCVParam:(MPGOCVParam *)param
{
    NSParameterAssert(param != nil);
    [_cvParams addObject:param];
}

- (void)removeCVParam:(MPGOCVParam *)param
{
    [_cvParams removeObject:param];
}

- (NSArray<MPGOCVParam *> *)allCVParams
{
    return [_cvParams copy];
}

- (NSArray<MPGOCVParam *> *)cvParamsForAccession:(NSString *)accession
{
    NSMutableArray *out = [NSMutableArray array];
    for (MPGOCVParam *p in _cvParams) {
        if ([p.accession isEqualToString:accession]) [out addObject:p];
    }
    return out;
}

- (NSArray<MPGOCVParam *> *)cvParamsForOntologyRef:(NSString *)ontologyRef
{
    NSMutableArray *out = [NSMutableArray array];
    for (MPGOCVParam *p in _cvParams) {
        if ([p.ontologyRef isEqualToString:ontologyRef]) [out addObject:p];
    }
    return out;
}

- (BOOL)hasCVParamWithAccession:(NSString *)accession
{
    for (MPGOCVParam *p in _cvParams) {
        if ([p.accession isEqualToString:accession]) return YES;
    }
    return NO;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOSignalArray class]]) return NO;
    MPGOSignalArray *o = (MPGOSignalArray *)other;
    if (_length != o.length) return NO;
    if (![_encoding isEqual:o.encoding]) return NO;
    if ((_axis || o.axis) && ![_axis isEqual:o.axis]) return NO;
    if (![_buffer isEqualToData:o.buffer]) return NO;
    if (_cvParams.count != [o allCVParams].count) return NO;
    NSArray *otherParams = [o allCVParams];
    for (NSUInteger i = 0; i < _cvParams.count; i++) {
        if (![_cvParams[i] isEqual:otherParams[i]]) return NO;
    }
    return YES;
}

- (NSUInteger)hash
{
    return _length ^ [_encoding hash] ^ [_buffer hash];
}

@end
