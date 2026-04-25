#import "TTIOInstrumentConfig.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOInstrumentConfig

- (instancetype)initWithManufacturer:(NSString *)manufacturer
                               model:(NSString *)model
                        serialNumber:(NSString *)serialNumber
                          sourceType:(NSString *)sourceType
                        analyzerType:(NSString *)analyzerType
                        detectorType:(NSString *)detectorType
{
    self = [super init];
    if (self) {
        _manufacturer = [(manufacturer ?: @"") copy];
        _model        = [(model        ?: @"") copy];
        _serialNumber = [(serialNumber ?: @"") copy];
        _sourceType   = [(sourceType   ?: @"") copy];
        _analyzerType = [(analyzerType ?: @"") copy];
        _detectorType = [(detectorType ?: @"") copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (instancetype)initWithCoder:(NSCoder *)c
{
    return [self initWithManufacturer:[c decodeObjectForKey:@"manufacturer"]
                                model:[c decodeObjectForKey:@"model"]
                         serialNumber:[c decodeObjectForKey:@"serialNumber"]
                           sourceType:[c decodeObjectForKey:@"sourceType"]
                         analyzerType:[c decodeObjectForKey:@"analyzerType"]
                         detectorType:[c decodeObjectForKey:@"detectorType"]];
}

- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:_manufacturer forKey:@"manufacturer"];
    [c encodeObject:_model        forKey:@"model"];
    [c encodeObject:_serialNumber forKey:@"serialNumber"];
    [c encodeObject:_sourceType   forKey:@"sourceType"];
    [c encodeObject:_analyzerType forKey:@"analyzerType"];
    [c encodeObject:_detectorType forKey:@"detectorType"];
}

- (BOOL)writeToGroup:(TTIOHDF5Group *)parent error:(NSError **)error
{
    TTIOHDF5Group *g = [parent createGroupNamed:@"instrument_config" error:error];
    if (!g) return NO;
    if (![g setStringAttribute:@"manufacturer" value:_manufacturer error:error]) return NO;
    if (![g setStringAttribute:@"model"        value:_model        error:error]) return NO;
    if (![g setStringAttribute:@"serial_number" value:_serialNumber error:error]) return NO;
    if (![g setStringAttribute:@"source_type"  value:_sourceType   error:error]) return NO;
    if (![g setStringAttribute:@"analyzer_type" value:_analyzerType error:error]) return NO;
    if (![g setStringAttribute:@"detector_type" value:_detectorType error:error]) return NO;
    return YES;
}

+ (instancetype)readFromGroup:(TTIOHDF5Group *)parent error:(NSError **)error
{
    TTIOHDF5Group *g = [parent openGroupNamed:@"instrument_config" error:error];
    if (!g) return nil;
    return [[self alloc] initWithManufacturer:[g stringAttributeNamed:@"manufacturer" error:error]
                                        model:[g stringAttributeNamed:@"model" error:error]
                                 serialNumber:[g stringAttributeNamed:@"serial_number" error:error]
                                   sourceType:[g stringAttributeNamed:@"source_type" error:error]
                                 analyzerType:[g stringAttributeNamed:@"analyzer_type" error:error]
                                 detectorType:[g stringAttributeNamed:@"detector_type" error:error]];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOInstrumentConfig class]]) return NO;
    TTIOInstrumentConfig *o = (TTIOInstrumentConfig *)other;
    return [_manufacturer isEqualToString:o.manufacturer]
        && [_model        isEqualToString:o.model]
        && [_serialNumber isEqualToString:o.serialNumber]
        && [_sourceType   isEqualToString:o.sourceType]
        && [_analyzerType isEqualToString:o.analyzerType]
        && [_detectorType isEqualToString:o.detectorType];
}

- (NSUInteger)hash { return [_manufacturer hash] ^ [_model hash] ^ [_serialNumber hash]; }

@end
