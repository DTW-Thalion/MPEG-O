#ifndef MPGO_AXIS_DESCRIPTOR_H
#define MPGO_AXIS_DESCRIPTOR_H

#import <Foundation/Foundation.h>
#import "MPGOEnums.h"
#import "MPGOValueRange.h"

/**
 * Describes a single axis of a SignalArray: its semantic name, unit,
 * numeric range, and sampling mode. Immutable value class.
 */
@interface MPGOAxisDescriptor : NSObject <NSCoding, NSCopying>

@property (readonly, copy)     NSString         *name;
@property (readonly, copy)     NSString         *unit;
@property (readonly, strong)   MPGOValueRange   *valueRange;
@property (readonly)           MPGOSamplingMode  samplingMode;

- (instancetype)initWithName:(NSString *)name
                        unit:(NSString *)unit
                  valueRange:(MPGOValueRange *)valueRange
                samplingMode:(MPGOSamplingMode)samplingMode;

+ (instancetype)descriptorWithName:(NSString *)name
                              unit:(NSString *)unit
                        valueRange:(MPGOValueRange *)valueRange
                      samplingMode:(MPGOSamplingMode)samplingMode;

@end

#endif /* MPGO_AXIS_DESCRIPTOR_H */
