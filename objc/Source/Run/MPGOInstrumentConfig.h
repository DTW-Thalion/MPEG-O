#ifndef MPGO_INSTRUMENT_CONFIG_H
#define MPGO_INSTRUMENT_CONFIG_H

#import <Foundation/Foundation.h>

@class MPGOHDF5Group;

/**
 * Immutable value class describing the instrument used to acquire a
 * run. Persisted as a small group of string attributes under
 * `instrument_config/` within the parent run group.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.instrument_config.InstrumentConfig
 *   Java:   com.dtwthalion.mpgo.InstrumentConfig
 */
@interface MPGOInstrumentConfig : NSObject <NSCopying, NSCoding>

@property (readonly, copy) NSString *manufacturer;
@property (readonly, copy) NSString *model;
@property (readonly, copy) NSString *serialNumber;
@property (readonly, copy) NSString *sourceType;
@property (readonly, copy) NSString *analyzerType;
@property (readonly, copy) NSString *detectorType;

- (instancetype)initWithManufacturer:(NSString *)manufacturer
                               model:(NSString *)model
                        serialNumber:(NSString *)serialNumber
                          sourceType:(NSString *)sourceType
                        analyzerType:(NSString *)analyzerType
                        detectorType:(NSString *)detectorType;

- (BOOL)writeToGroup:(MPGOHDF5Group *)parent error:(NSError **)error;
+ (instancetype)readFromGroup:(MPGOHDF5Group *)parent error:(NSError **)error;

@end

#endif
