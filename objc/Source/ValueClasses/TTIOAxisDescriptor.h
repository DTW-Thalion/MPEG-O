#ifndef TTIO_AXIS_DESCRIPTOR_H
#define TTIO_AXIS_DESCRIPTOR_H

#import <Foundation/Foundation.h>
#import "TTIOEnums.h"
#import "TTIOValueRange.h"

/**
 * <heading>TTIOAxisDescriptor</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCoding, NSCopying</p>
 * <p><em>Declared In:</em> ValueClasses/TTIOAxisDescriptor.h</p>
 *
 * <p>Describes a single axis of a <code>TTIOSignalArray</code>: its
 * semantic name (e.g. <code>@"m/z"</code>, <code>@"intensity"</code>,
 * <code>@"chemical_shift"</code>), unit string (UCUM-compatible, e.g.
 * <code>@"Th"</code> or <code>@"ppm"</code>), numeric range, and
 * sampling mode. Immutable value class with value-based equality.</p>
 *
 * <p>The sampling mode distinguishes between uniformly-spaced
 * (e.g. constant-time mass-spectrum scans) and irregularly-spaced
 * (e.g. centroided peak lists) axes; see
 * <code>TTIOSamplingMode</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.axis_descriptor.AxisDescriptor</code><br/>
 * Java: <code>global.thalion.ttio.AxisDescriptor</code></p>
 */
@interface TTIOAxisDescriptor : NSObject <NSCoding, NSCopying>

/** Semantic axis name. */
@property (readonly, copy) NSString *name;

/** UCUM-compatible unit string. */
@property (readonly, copy) NSString *unit;

/** Numeric bounds of the axis. */
@property (readonly, strong) TTIOValueRange *valueRange;

/** Whether the axis samples uniformly or irregularly. */
@property (readonly) TTIOSamplingMode samplingMode;

/**
 * Designated initialiser.
 *
 * @param name         Semantic axis name; must not be <code>nil</code>.
 * @param unit         Unit string; must not be <code>nil</code>.
 * @param valueRange   Numeric bounds; must not be <code>nil</code>.
 * @param samplingMode Sampling mode enum value.
 * @return An initialised descriptor.
 */
- (instancetype)initWithName:(NSString *)name
                        unit:(NSString *)unit
                  valueRange:(TTIOValueRange *)valueRange
                samplingMode:(TTIOSamplingMode)samplingMode;

/**
 * Convenience factory for <code>-initWithName:unit:valueRange:samplingMode:</code>.
 *
 * @param name         Semantic axis name.
 * @param unit         Unit string.
 * @param valueRange   Numeric bounds.
 * @param samplingMode Sampling mode enum value.
 * @return An autoreleased descriptor.
 */
+ (instancetype)descriptorWithName:(NSString *)name
                              unit:(NSString *)unit
                        valueRange:(TTIOValueRange *)valueRange
                      samplingMode:(TTIOSamplingMode)samplingMode;

@end

#endif /* TTIO_AXIS_DESCRIPTOR_H */
