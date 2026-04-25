#ifndef TTIO_ISOLATION_WINDOW_H
#define TTIO_ISOLATION_WINDOW_H

#import <Foundation/Foundation.h>

/**
 * Precursor isolation window for MS/MS scans, expressed as a target m/z
 * with asymmetric lower/upper offsets in Th (Da). Immutable value class.
 *
 * The instrument-reported window spans
 * `[targetMz - lowerOffset, targetMz + upperOffset]`. Offsets are
 * non-negative by convention; the lower and upper may differ when the
 * quadrupole is offset from the monoisotopic m/z (common in DIA).
 *
 * API status: Stable (v1.1, M74).
 *
 * Cross-language equivalents:
 *   Python: ttio.isolation_window.IsolationWindow
 *   Java:   global.thalion.ttio.IsolationWindow
 */
@interface TTIOIsolationWindow : NSObject <NSCoding, NSCopying>

@property (readonly) double targetMz;
@property (readonly) double lowerOffset;
@property (readonly) double upperOffset;

- (instancetype)initWithTargetMz:(double)targetMz
                     lowerOffset:(double)lowerOffset
                     upperOffset:(double)upperOffset;

+ (instancetype)windowWithTargetMz:(double)targetMz
                       lowerOffset:(double)lowerOffset
                       upperOffset:(double)upperOffset;

- (double)lowerBound;
- (double)upperBound;
- (double)width;

@end

#endif /* TTIO_ISOLATION_WINDOW_H */
