#import "TTIOSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
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

- (BOOL)writeToGroup:(TTIOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    TTIOHDF5Group *group = [parent createGroupNamed:name error:error];
    if (!group) return NO;

    if (![group setStringAttribute:@"ttio_class"
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
        TTIOHDF5Dataset *d = [group createDatasetNamed:@"_scan_time"
                                              precision:TTIOPrecisionFloat64
                                                 length:1
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
        if (!d) return NO;
        if (![d writeData:[NSData dataWithBytes:sd length:sizeof(sd)] error:error]) return NO;
    }
    {
        double pmz[1] = { _precursorMz };
        TTIOHDF5Dataset *d = [group createDatasetNamed:@"_precursor_mz"
                                              precision:TTIOPrecisionFloat64
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
    TTIOHDF5Group *arrays = [group createGroupNamed:@"arrays" error:error];
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

+ (instancetype)readFromGroup:(TTIOHDF5Group *)parent name:(NSString *)name error:(NSError **)error
{
    TTIOHDF5Group *group = [parent openGroupNamed:name error:error];
    if (!group) return nil;

    BOOL exists = NO;
    NSUInteger indexPosition = (NSUInteger)[group integerAttributeNamed:@"index_position"
                                                                exists:&exists
                                                                 error:error];
    if (!exists) return nil;

    TTIOHDF5Dataset *stD = [group openDatasetNamed:@"_scan_time" error:error];
    NSData *stData = [stD readDataWithError:error];
    if (!stData) return nil;
    double scanTime = ((const double *)stData.bytes)[0];

    TTIOHDF5Dataset *pmzD = [group openDatasetNamed:@"_precursor_mz" error:error];
    NSData *pmzData = [pmzD readDataWithError:error];
    if (!pmzData) return nil;
    double precursorMz = ((const double *)pmzData.bytes)[0];

    NSUInteger precursorCharge =
        (NSUInteger)[group integerAttributeNamed:@"precursor_charge"
                                          exists:&exists error:error];

    TTIOHDF5Group *arraysGroup = [group openGroupNamed:@"arrays" error:error];
    if (!arraysGroup) return nil;
    NSString *namesStr = [arraysGroup stringAttributeNamed:@"_array_names" error:error];
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

- (BOOL)writeAdditionalAttributesToGroup:(TTIOHDF5Group *)group error:(NSError **)error
{
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(TTIOHDF5Group *)group error:(NSError **)error
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
