#ifndef TTIO_QUERY_H
#define TTIO_QUERY_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOSpectrumIndex;
@class TTIOValueRange;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Query/TTIOQuery.h</p>
 *
 * <p>Compressed-domain query against a
 * <code>TTIOSpectrumIndex</code>. Predicates are combined with logical
 * AND (intersection). The query operates entirely on the in-memory
 * index arrays &#8212; signal-channel datasets are never opened, so a
 * 10k-spectrum scan completes in well under a millisecond and never
 * touches the encrypted intensity stream.</p>
 *
 * <p>Builder-style chaining is encouraged:</p>
 *
 * <pre>
 *     NSIndexSet *hits =
 *         [[[[TTIOQuery queryOnIndex:run.spectrumIndex]
 *             withMsLevel:2]
 *             withRetentionTimeRange:[TTIOValueRange rangeWithMinimum:600
 *                                                              maximum:720]]
 *             withPrecursorMzRange:[TTIOValueRange rangeWithMinimum:500
 *                                                            maximum:550]]
 *             matchingIndices];
 * </pre>
 *
 * <p>Each <code>withXxx:</code> setter returns <code>self</code> so
 * predicates can be combined fluently. A query without predicates
 * returns every spectrum index in the run.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.query.Query</code><br/>
 * Java: <code>global.thalion.ttio.Query</code></p>
 */
@interface TTIOQuery : NSObject

#pragma mark - Construction

/**
 * Returns a freshly initialised query with no predicates set.
 *
 * @param index Spectrum index to query against. Must be non-nil; the
 *              returned query holds a strong reference for the duration
 *              of its lifetime.
 * @return A new query instance. Apply predicates with the
 *         <code>-withXxx:</code> chain, then read results via
 *         <code>-matchingIndices</code>.
 */
+ (instancetype)queryOnIndex:(TTIOSpectrumIndex *)index;

#pragma mark - Predicate chain

/**
 * Restricts results to spectra whose retention time falls inside
 * <code>range</code> (closed interval, seconds).
 *
 * @param range Inclusive retention-time range.
 * @return <code>self</code> for chaining.
 */
- (TTIOQuery *)withRetentionTimeRange:(TTIOValueRange *)range;

/**
 * Restricts results to spectra acquired at the given MS level
 * (1 = MS1, 2 = MS2, ...).
 *
 * @param level MS level to match exactly.
 * @return <code>self</code> for chaining.
 */
- (TTIOQuery *)withMsLevel:(uint8_t)level;

/**
 * Restricts results to spectra acquired with the given ionisation
 * polarity.
 *
 * @param polarity Polarity enum value to match exactly.
 * @return <code>self</code> for chaining.
 */
- (TTIOQuery *)withPolarity:(TTIOPolarity)polarity;

/**
 * Restricts MSn results to spectra whose precursor m/z falls inside
 * <code>range</code> (closed interval). Has no effect on MS1 spectra
 * unless combined with <code>-withMsLevel:</code>.
 *
 * @param range Inclusive precursor-m/z range.
 * @return <code>self</code> for chaining.
 */
- (TTIOQuery *)withPrecursorMzRange:(TTIOValueRange *)range;

/**
 * Restricts results to spectra whose base-peak intensity meets or
 * exceeds <code>threshold</code>.
 *
 * @param threshold Minimum acceptable base-peak intensity (counts or
 *                  arbitrary units, as recorded in the index).
 * @return <code>self</code> for chaining.
 */
- (TTIOQuery *)withBasePeakIntensityAtLeast:(double)threshold;

#pragma mark - Evaluation

/**
 * Evaluates the accumulated predicates against the bound spectrum
 * index and returns the matching positions in ascending order.
 *
 * @return An <code>NSIndexSet</code> containing every spectrum index
 *         that satisfies <em>all</em> applied predicates. Empty if
 *         none match. Never <code>nil</code>.
 */
- (NSIndexSet *)matchingIndices;

@end

#endif
