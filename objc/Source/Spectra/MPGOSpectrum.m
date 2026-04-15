#import "MPGOSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOAxisDescriptor.h"

@implementation MPGOSpectrum

- (instancetype)initWithSignalArrays:(NSDictionary<NSString *, MPGOSignalArray *> *)arrays
                                axes:(NSArray<MPGOAxisDescriptor *> *)axes
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

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    MPGOHDF5Group *group = [parent createGroupNamed:name error:error];
    if (!group) return NO;

    if (![group setStringAttribute:@"mpgo_class"
                              value:NSStringFromClass([self class])
                              error:error]) return NO;
    if (![group setIntegerAttribute:@"index_position"
                              value:(int64_t)_indexPosition
                              error:error]) return NO;

    // Scan time and precursor mz are doubles; pack each as a 1-element
    // dataset so we don't need a typed-double attribute path. Keep this
    // simple: store as base64 of bytes via a string attribute? No —
    // use the existing 1-element float64 dataset trick.
    {
        double sd[1] = { _scanTimeSeconds };
        MPGOHDF5Dataset *d = [group createDatasetNamed:@"_scan_time"
                                              precision:MPGOPrecisionFloat64
                                                 length:1
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
        if (!d) return NO;
        if (![d writeData:[NSData dataWithBytes:sd length:sizeof(sd)] error:error]) return NO;
    }
    {
        double pmz[1] = { _precursorMz };
        MPGOHDF5Dataset *d = [group createDatasetNamed:@"_precursor_mz"
                                              precision:MPGOPrecisionFloat64
                                                 length:1
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
        if (!d) return NO;
        if (![d writeData:[NSData dataWithBytes:pmz length:sizeof(pmz)] error:error]) return NO;
    }
    if (![group setIntegerAttribute:@"precursor_charge"
                              value:(int64_t)_precursorCharge
                              error:error]) return NO;

    // SignalArrays as named sub-groups under "arrays/".
    MPGOHDF5Group *arrays = [group createGroupNamed:@"arrays" error:error];
    if (!arrays) return NO;
    NSArray *names = [[_signalArrays allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![arrays setStringAttribute:@"_array_names"
                              value:[names componentsJoinedByString:@","]
                              error:error]) return NO;
    for (NSString *aname in names) {
        if (![_signalArrays[aname] writeToGroup:arrays
                                           name:aname
                                      chunkSize:1024
                               compressionLevel:6
                                          error:error]) return NO;
    }

    return [self writeAdditionalAttributesToGroup:group error:error];
}

+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    MPGOHDF5Group *group = [parent openGroupNamed:name error:error];
    if (!group) return nil;

    BOOL exists = NO;
    NSUInteger indexPosition = (NSUInteger)[group integerAttributeNamed:@"index_position"
                                                                exists:&exists
                                                                 error:error];
    if (!exists) return nil;

    MPGOHDF5Dataset *stD = [group openDatasetNamed:@"_scan_time" error:error];
    NSData *stData = [stD readDataWithError:error];
    if (!stData) return nil;
    double scanTime = ((const double *)stData.bytes)[0];

    MPGOHDF5Dataset *pmzD = [group openDatasetNamed:@"_precursor_mz" error:error];
    NSData *pmzData = [pmzD readDataWithError:error];
    if (!pmzData) return nil;
    double precursorMz = ((const double *)pmzData.bytes)[0];

    NSUInteger precursorCharge =
        (NSUInteger)[group integerAttributeNamed:@"precursor_charge"
                                          exists:&exists error:error];

    MPGOHDF5Group *arraysGroup = [group openGroupNamed:@"arrays" error:error];
    if (!arraysGroup) return nil;
    NSString *namesStr = [arraysGroup stringAttributeNamed:@"_array_names" error:error];
    NSArray *names = [namesStr componentsSeparatedByString:@","];
    NSMutableDictionary *arrays = [NSMutableDictionary dictionary];
    for (NSString *aname in names) {
        if (aname.length == 0) continue;
        MPGOSignalArray *sa = [MPGOSignalArray readFromGroup:arraysGroup
                                                        name:aname
                                                       error:error];
        if (!sa) return nil;
        arrays[aname] = sa;
    }

    MPGOSpectrum *spec = [[self alloc] initWithSignalArrays:arrays
                                                       axes:@[]
                                              indexPosition:indexPosition
                                            scanTimeSeconds:scanTime
                                                precursorMz:precursorMz
                                            precursorCharge:precursorCharge];
    if (![spec readAdditionalAttributesFromGroup:group error:error]) return nil;
    return spec;
}

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    return YES;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOSpectrum class]]) return NO;
    MPGOSpectrum *o = (MPGOSpectrum *)other;
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
