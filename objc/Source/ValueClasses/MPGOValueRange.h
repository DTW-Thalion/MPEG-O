#ifndef MPGO_VALUE_RANGE_H
#define MPGO_VALUE_RANGE_H

#import <Foundation/Foundation.h>

/**
 * Closed numeric range [minimum, maximum]. Immutable value class.
 * Used by MPGOAxisDescriptor to describe the bounds of a signal axis.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.value_range.ValueRange
 *   Java:   com.dtwthalion.mpgo.ValueRange
 */
@interface MPGOValueRange : NSObject <NSCoding, NSCopying>

@property (readonly) double minimum;
@property (readonly) double maximum;

- (instancetype)initWithMinimum:(double)minimum maximum:(double)maximum;
+ (instancetype)rangeWithMinimum:(double)minimum maximum:(double)maximum;

- (double)span;
- (BOOL)containsValue:(double)value;

@end

#endif /* MPGO_VALUE_RANGE_H */
