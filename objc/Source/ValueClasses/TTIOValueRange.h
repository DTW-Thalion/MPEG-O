#ifndef TTIO_VALUE_RANGE_H
#define TTIO_VALUE_RANGE_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCoding, NSCopying</p>
 * <p><em>Declared In:</em> ValueClasses/TTIOValueRange.h</p>
 *
 * <p>Closed numeric range <code>[minimum, maximum]</code>. Immutable
 * value class used by <code>TTIOAxisDescriptor</code> to describe
 * the bounds of a signal axis. Equality is value-based on the two
 * doubles; <code>-copyWithZone:</code> returns <code>self</code>.</p>
 *
 * <p>Construction does not enforce <code>minimum &lt;= maximum</code>;
 * a degenerate or inverted range is well-defined for storage but
 * <code>-containsValue:</code> will always return <code>NO</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.value_range.ValueRange</code><br/>
 * Java: <code>global.thalion.ttio.ValueRange</code></p>
 */
@interface TTIOValueRange : NSObject <NSCoding, NSCopying>

/** Lower bound of the closed range. */
@property (readonly) double minimum;

/** Upper bound of the closed range. */
@property (readonly) double maximum;

/**
 * Designated initialiser.
 *
 * @param minimum Lower bound.
 * @param maximum Upper bound.
 * @return An initialised range.
 */
- (instancetype)initWithMinimum:(double)minimum maximum:(double)maximum;

/**
 * Convenience factory for <code>-initWithMinimum:maximum:</code>.
 *
 * @param minimum Lower bound.
 * @param maximum Upper bound.
 * @return An autoreleased range.
 */
+ (instancetype)rangeWithMinimum:(double)minimum maximum:(double)maximum;

/**
 * @return The width of the range, <code>maximum - minimum</code>.
 *         Negative for inverted ranges.
 */
- (double)span;

/**
 * Tests whether a value lies within the closed range.
 *
 * @param value The value to test.
 * @return <code>YES</code> if
 *         <code>minimum &lt;= value &lt;= maximum</code>.
 */
- (BOOL)containsValue:(double)value;

@end

#endif /* TTIO_VALUE_RANGE_H */
