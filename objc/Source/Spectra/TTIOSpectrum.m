#import "TTIOSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOAxisDescriptor.h"

@implementation TTIOSpectrum

- (instancetype)initWithSignalArrays:(NSDictionary<NSString *, TTIOSignalArray *> *)arrays
                                axes:(NSArray<TTIOAxisDescriptor *> *)axes
                       indexPosition:(NSUInteger)indexPosition
                     scanTimeSeconds:(double)scanTime
                         precursorMz:(double)precursorMz
                     precursorCharge:(NSUInteger)precursorCharge
{
    self = [super init];
    if (self) {
        _signalArrays    = [arrays copy];
        _axes            = [axes copy];
        _indexPosition   = indexPosition;
        _scanTimeSeconds = scanTime;
        _precursorMz     = precursorMz;
        _precursorCharge = precursorCharge;
    }
    return self;
}

#pragma mark - HDF5

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent name:(NSString *)name error:(NSError **)error
{
    id<TTIOStorageGroup> group = [parent createGroupNamed:name error:error];
    if (!group) return NO;

    if (![group setAttributeValue:NSStringFromClass([self class])
                          forName:@"ttio_class" error:error]) return NO;
    if (![group setAttributeValue:@((int64_t)_indexPosition)
                          forName:@"index_position" error:error]) return NO;

    // Scan time and precursor mz are doubles; pack each as a 1-element
    // dataset so we don't need a typed-double attribute path.
    {
        double sd[1] = { _scanTimeSeconds };
        id<TTIOStorageDataset> d = [group createDatasetNamed:@"_scan_time"
                                                   precision:TTIOPrecisionFloat64
                                                      length:1
                                                   chunkSize:0
                                                 compression:TTIOCompressionZlib
                                            compressionLevel:0
                                                       error:error];
        if (!d) return NO;
        if (![d writeAll:[NSData dataWithBytes:sd length:sizeof(sd)] error:error]) return NO;
    }
    {
        double pmz[1] = { _precursorMz };
        id<TTIOStorageDataset> d = [group createDatasetNamed:@"_precursor_mz"
                                                   precision:TTIOPrecisionFloat64
                                                      length:1
                                                   chunkSize:0
                                                 compression:TTIOCompressionZlib
                                            compressionLevel:0
                                                       error:error];
        if (!d) return NO;
        if (![d writeAll:[NSData dataWithBytes:pmz length:sizeof(pmz)] error:error]) return NO;
    }
    if (![group setAttributeValue:@((int64_t)_precursorCharge)
                          forName:@"precursor_charge" error:error]) return NO;

    // SignalArrays as named sub-groups under "arrays/".
    id<TTIOStorageGroup> arrays = [group createGroupNamed:@"arrays" error:error];
    if (!arrays) return NO;
    NSArray *names = [[_signalArrays allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![arrays setAttributeValue:[names componentsJoinedByString:@","]
                           forName:@"_array_names" error:error]) return NO;
    for (NSString *aname in names) {
        if (![_signalArrays[aname] writeToGroup:arrays
                                           name:aname
                                      chunkSize:1024
                               compressionLevel:6
                                          error:error]) return NO;
    }

    return [self writeAdditionalAttributesToGroup:group error:error];
}

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent name:(NSString *)name error:(NSError **)error
{
    id<TTIOStorageGroup> group = [parent openGroupNamed:name error:error];
    if (!group) return nil;

    NSNumber *idxNum = [group attributeValueForName:@"index_position" error:error];
    if (!idxNum) return nil;
    NSUInteger indexPosition = (NSUInteger)[idxNum longLongValue];

    id<TTIOStorageDataset> stD = [group openDatasetNamed:@"_scan_time" error:error];
    NSData *stData = [stD readAll:error];
    if (!stData) return nil;
    double scanTime = ((const double *)stData.bytes)[0];

    id<TTIOStorageDataset> pmzD = [group openDatasetNamed:@"_precursor_mz" error:error];
    NSData *pmzData = [pmzD readAll:error];
    if (!pmzData) return nil;
    double precursorMz = ((const double *)pmzData.bytes)[0];

    NSNumber *pchgNum = [group attributeValueForName:@"precursor_charge" error:error];
    NSUInteger precursorCharge = pchgNum ? (NSUInteger)[pchgNum longLongValue] : 0;

    id<TTIOStorageGroup> arraysGroup = [group openGroupNamed:@"arrays" error:error];
    if (!arraysGroup) return nil;
    NSString *namesStr = [arraysGroup attributeValueForName:@"_array_names" error:error];
    NSArray *names = [namesStr componentsSeparatedByString:@","];
    NSMutableDictionary *arrays = [NSMutableDictionary dictionary];
    for (NSString *aname in names) {
        if (aname.length == 0) continue;
        TTIOSignalArray *sa = [TTIOSignalArray readFromGroup:arraysGroup
                                                        name:aname
                                                       error:error];
        if (!sa) return nil;
        arrays[aname] = sa;
    }

    TTIOSpectrum *spec = [[self alloc] initWithSignalArrays:arrays
                                                       axes:@[]
                                              indexPosition:indexPosition
                                            scanTimeSeconds:scanTime
                                                precursorMz:precursorMz
                                            precursorCharge:precursorCharge];
    if (![spec readAdditionalAttributesFromGroup:group error:error]) return nil;
    return spec;
}

- (BOOL)writeAdditionalAttributesToGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(id<TTIOStorageGroup>)group error:(NSError **)error
{
    return YES;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOSpectrum class]]) return NO;
    TTIOSpectrum *o = (TTIOSpectrum *)other;
    if (_indexPosition != o.indexPosition) return NO;
    if (_scanTimeSeconds != o.scanTimeSeconds) return NO;
    if (_precursorMz != o.precursorMz) return NO;
    if (_precursorCharge != o.precursorCharge) return NO;
    if (![_signalArrays isEqual:o.signalArrays]) return NO;
    return YES;
}

- (NSUInteger)hash
{
    return _indexPosition ^ (NSUInteger)_scanTimeSeconds ^ [_signalArrays count];
}

@end
