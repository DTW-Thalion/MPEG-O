#ifndef TTIO_AXIS_DESCRIPTOR_H
#define TTIO_AXIS_DESCRIPTOR_H

#import <Foundation/Foundation.h>
#import "TTIOEnums.h"
#import "TTIOValueRange.h"

/**
 * Describes a single axis of a SignalArray: its semantic name, unit,
 * numeric range, and sampling mode. Immutable value class.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.axis_descriptor.AxisDescriptor
 *   Java:   global.thalion.ttio.AxisDescriptor
 */
@interface TTIOAxisDescriptor : NSObject <NSCoding, NSCopying>

@property (readonly, copy)     NSString         *name;
@property (readonly, copy)     NSString         *unit;
@property (readonly, strong)   TTIOValueRange   *valueRange;
@property (readonly)           TTIOSamplingMode  samplingMode;

- (instancetype)initWithName:(NSString *)name
                        unit:(NSString *)unit
                  valueRange:(TTIOValueRange *)valueRange
                samplingMode:(TTIOSamplingMode)samplingMode;

+ (instancetype)descriptorWithName:(NSString *)name
                              unit:(NSString *)unit
                        valueRange:(TTIOValueRange *)valueRange
                      samplingMode:(TTIOSamplingMode)samplingMode;

@end

#endif /* TTIO_AXIS_DESCRIPTOR_H */
