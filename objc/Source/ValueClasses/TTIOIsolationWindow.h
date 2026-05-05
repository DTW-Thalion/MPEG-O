#ifndef TTIO_ISOLATION_WINDOW_H
#define TTIO_ISOLATION_WINDOW_H

#import <Foundation/Foundation.h>

/**
 * <heading>TTIOIsolationWindow</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCoding, NSCopying</p>
 * <p><em>Declared In:</em> ValueClasses/TTIOIsolationWindow.h</p>
 *
 * <p>Precursor isolation window for MS/MS scans, expressed as a
 * target m/z with asymmetric lower/upper offsets in Th (Da).
 * Immutable value class with value-based equality.</p>
 *
 * <p>The instrument-reported window spans
 * <code>[targetMz - lowerOffset, targetMz + upperOffset]</code>.
 * Offsets are non-negative by convention; the lower and upper may
 * differ when the quadrupole is offset from the monoisotopic m/z
 * (common in DIA acquisitions).</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.isolation_window.IsolationWindow</code><br/>
 * Java: <code>global.thalion.ttio.IsolationWindow</code></p>
 */
@interface TTIOIsolationWindow : NSObject <NSCoding, NSCopying>

/** Target m/z of the isolation. */
@property (readonly) double targetMz;

/** Lower offset from <code>targetMz</code> (non-negative). */
@property (readonly) double lowerOffset;

/** Upper offset from <code>targetMz</code> (non-negative). */
@property (readonly) double upperOffset;

/**
 * Designated initialiser.
 *
 * @param targetMz    Target m/z of the isolation.
 * @param lowerOffset Lower offset from <code>targetMz</code>.
 * @param upperOffset Upper offset from <code>targetMz</code>.
 * @return An initialised isolation window.
 */
- (instancetype)initWithTargetMz:(double)targetMz
                     lowerOffset:(double)lowerOffset
                     upperOffset:(double)upperOffset;

/**
 * Convenience factory for the designated initialiser.
 *
 * @param targetMz    Target m/z.
 * @param lowerOffset Lower offset.
 * @param upperOffset Upper offset.
 * @return An autoreleased isolation window.
 */
+ (instancetype)windowWithTargetMz:(double)targetMz
                       lowerOffset:(double)lowerOffset
                       upperOffset:(double)upperOffset;

/** @return <code>targetMz - lowerOffset</code>. */
- (double)lowerBound;

/** @return <code>targetMz + upperOffset</code>. */
- (double)upperBound;

/** @return <code>lowerOffset + upperOffset</code> (the total width). */
- (double)width;

@end

#endif /* TTIO_ISOLATION_WINDOW_H */
