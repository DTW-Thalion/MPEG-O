/*
 * TTIOSignalArray.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOSignalArray
 * Inherits From: NSObject
 * Conforms To:   TTIOCVAnnotatable
 * Declared In:   Core/TTIOSignalArray.h
 *
 * The atomic unit of measured signal in TTI-O. Wraps a typed
 * numeric buffer with encoding metadata, an optional axis
 * descriptor, and CV annotations. This file implements
 * provider-agnostic storage round-trip, equality, hashing, and
 * the CVAnnotatable protocol methods.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOSignalArray
{
    NSMutableArray<TTIOCVParam *> *_cvParams;
}

- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(TTIOEncodingSpec *)encoding
                          axis:(TTIOAxisDescriptor *)axis
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

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)group
                name:(NSString *)name
           chunkSize:(NSUInteger)chunkSize
    compressionLevel:(int)compressionLevel
               error:(NSError **)error
{
    id<TTIOStorageGroup> sub = [group createGroupNamed:name error:error];
    if (!sub) return NO;

    id<TTIOStorageDataset> ds =
        [sub createDatasetNamed:@"buffer"
                      precision:_encoding.precision
                         length:_length
                      chunkSize:chunkSize
                    compression:TTIOCompressionZlib
               compressionLevel:compressionLevel
                          error:error];
    if (!ds) return NO;
    if (![ds writeAll:_buffer error:error]) return NO;

    if (![sub setAttributeValue:@((int64_t)_encoding.compressionAlgorithm)
                        forName:@"compression" error:error]) return NO;
    if (![sub setAttributeValue:@((int64_t)_encoding.byteOrder)
                        forName:@"byte_order" error:error]) return NO;
    if (![sub setAttributeValue:@((int64_t)_encoding.precision)
                        forName:@"precision" error:error]) return NO;

    if (_axis) {
        if (![sub setAttributeValue:_axis.name forName:@"axis_name" error:error]) return NO;
        if (![sub setAttributeValue:_axis.unit forName:@"axis_unit" error:error]) return NO;
        if (![sub setAttributeValue:@((int64_t)_axis.samplingMode)
                            forName:@"axis_sampling_mode" error:error]) return NO;
        // Encode range as two doubles via a dataset to keep the attribute API simple.
        id<TTIOStorageDataset> rng =
            [sub createDatasetNamed:@"axis_range"
                          precision:TTIOPrecisionFloat64
                             length:2
                          chunkSize:0
                        compression:TTIOCompressionZlib
                   compressionLevel:0
                              error:error];
        if (!rng) return NO;
        double r[2] = { _axis.valueRange.minimum, _axis.valueRange.maximum };
        NSData *rdata = [NSData dataWithBytes:r length:sizeof(r)];
        if (![rng writeAll:rdata error:error]) return NO;
    }

    if (_cvParams.count > 0) {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:_cvParams.count];
        for (TTIOCVParam *p in _cvParams) {
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
        if (![sub setAttributeValue:jsonStr forName:@"cv_params" error:error]) return NO;
    }

    return YES;
}

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)group
                         name:(NSString *)name
                        error:(NSError **)error
{
    id<TTIOStorageGroup> sub = [group openGroupNamed:name error:error];
    if (!sub) return nil;

    id<TTIOStorageDataset> ds = [sub openDatasetNamed:@"buffer" error:error];
    if (!ds) return nil;

    NSData *bytes = [ds readAll:error];
    if (!bytes) return nil;

    NSNumber *compNum = [sub attributeValueForName:@"compression" error:error];
    if (!compNum) {
        if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"signal array missing 'compression' attribute");
        return nil;
    }
    NSNumber *byteNum = [sub attributeValueForName:@"byte_order" error:error];
    if (!byteNum) return nil;

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:ds.precision
                       compressionAlgorithm:(TTIOCompression)[compNum longLongValue]
                                  byteOrder:(TTIOByteOrder)[byteNum longLongValue]];

    TTIOAxisDescriptor *axis = nil;
    if ([sub hasAttributeNamed:@"axis_name"]) {
        NSString *axName = [sub attributeValueForName:@"axis_name" error:error];
        NSString *axUnit = [sub attributeValueForName:@"axis_unit" error:error];
        NSNumber *axModeNum = [sub attributeValueForName:@"axis_sampling_mode"
                                                   error:error];
        int64_t axMode = axModeNum ? [axModeNum longLongValue] : 0;
        id<TTIOStorageDataset> rng = [sub openDatasetNamed:@"axis_range" error:error];
        if (!rng) return nil;
        NSData *rdata = [rng readAll:error];
        if (!rdata || rdata.length < 2 * sizeof(double)) return nil;
        const double *rp = rdata.bytes;
        TTIOValueRange *vr = [TTIOValueRange rangeWithMinimum:rp[0] maximum:rp[1]];
        axis = [TTIOAxisDescriptor descriptorWithName:axName
                                                 unit:axUnit
                                           valueRange:vr
                                         samplingMode:(TTIOSamplingMode)axMode];
    }

    TTIOSignalArray *arr = [[self alloc] initWithBuffer:bytes
                                                 length:ds.length
                                               encoding:enc
                                                   axis:axis];

    if ([sub hasAttributeNamed:@"cv_params"]) {
        NSString *json = [sub attributeValueForName:@"cv_params" error:error];
        NSData *jdata = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *items = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:error];
        for (NSDictionary *d in items) {
            TTIOCVParam *p =
                [TTIOCVParam paramWithOntologyRef:d[@"ontologyRef"]
                                        accession:d[@"accession"]
                                             name:d[@"name"]
                                            value:d[@"value"]
                                             unit:d[@"unit"]];
            [arr addCVParam:p];
        }
    }

    return arr;
}

#pragma mark - TTIOCVAnnotatable

- (void)addCVParam:(TTIOCVParam *)param
{
    NSParameterAssert(param != nil);
    [_cvParams addObject:param];
}

- (void)removeCVParam:(TTIOCVParam *)param
{
    [_cvParams removeObject:param];
}

- (NSArray<TTIOCVParam *> *)allCVParams
{
    return [_cvParams copy];
}

- (NSArray<TTIOCVParam *> *)cvParamsForAccession:(NSString *)accession
{
    NSMutableArray *out = [NSMutableArray array];
    for (TTIOCVParam *p in _cvParams) {
        if ([p.accession isEqualToString:accession]) [out addObject:p];
    }
    return out;
}

- (NSArray<TTIOCVParam *> *)cvParamsForOntologyRef:(NSString *)ontologyRef
{
    NSMutableArray *out = [NSMutableArray array];
    for (TTIOCVParam *p in _cvParams) {
        if ([p.ontologyRef isEqualToString:ontologyRef]) [out addObject:p];
    }
    return out;
}

- (BOOL)hasCVParamWithAccession:(NSString *)accession
{
    for (TTIOCVParam *p in _cvParams) {
        if ([p.accession isEqualToString:accession]) return YES;
    }
    return NO;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOSignalArray class]]) return NO;
    TTIOSignalArray *o = (TTIOSignalArray *)other;
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
