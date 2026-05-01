#ifndef TTIO_INSTRUMENT_CONFIG_H
#define TTIO_INSTRUMENT_CONFIG_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"

/**
 * Immutable value class describing the instrument used to acquire a
 * run. Persisted as a small group of string attributes under
 * `instrument_config/` within the parent run group.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.instrument_config.InstrumentConfig
 *   Java:   global.thalion.ttio.InstrumentConfig
 */
@interface TTIOInstrumentConfig : NSObject <NSCopying, NSCoding>

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

- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent error:(NSError **)error;
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent error:(NSError **)error;

@end

#endif
