/*
 * TTIOInstrumentConfig.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOInstrumentConfig
 * Inherits From: NSObject
 * Conforms To:   NSCoding, NSCopying
 * Declared In:   Run/TTIOInstrumentConfig.h
 *
 * Immutable instrument-configuration value class. Persisted as a
 * small group of string attributes under instrument_config/.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOInstrumentConfig.h"
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

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent error:(NSError **)error
{
    id<TTIOStorageGroup> g = [parent createGroupNamed:@"instrument_config" error:error];
    if (!g) return NO;
    if (![g setAttributeValue:_manufacturer forName:@"manufacturer"  error:error]) return NO;
    if (![g setAttributeValue:_model        forName:@"model"         error:error]) return NO;
    if (![g setAttributeValue:_serialNumber forName:@"serial_number" error:error]) return NO;
    if (![g setAttributeValue:_sourceType   forName:@"source_type"   error:error]) return NO;
    if (![g setAttributeValue:_analyzerType forName:@"analyzer_type" error:error]) return NO;
    if (![g setAttributeValue:_detectorType forName:@"detector_type" error:error]) return NO;
    return YES;
}

+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent error:(NSError **)error
{
    id<TTIOStorageGroup> g = [parent openGroupNamed:@"instrument_config" error:error];
    if (!g) return nil;
    return [[self alloc] initWithManufacturer:[g attributeValueForName:@"manufacturer"  error:error]
                                        model:[g attributeValueForName:@"model"         error:error]
                                 serialNumber:[g attributeValueForName:@"serial_number" error:error]
                                   sourceType:[g attributeValueForName:@"source_type"   error:error]
                                 analyzerType:[g attributeValueForName:@"analyzer_type" error:error]
                                 detectorType:[g attributeValueForName:@"detector_type" error:error]];
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
