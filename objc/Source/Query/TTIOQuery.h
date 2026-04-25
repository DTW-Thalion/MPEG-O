#ifndef TTIO_QUERY_H
#define TTIO_QUERY_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOSpectrumIndex;
@class TTIOValueRange;

/**
 * Compressed-domain query against an TTIOSpectrumIndex. Predicates are
 * combined with AND (intersection). The query operates entirely on the
 * in-memory index arrays — signal-channel datasets are never opened, so
 * a 10k-spectrum scan completes in under a millisecond and never touches
 * the encrypted intensity stream.
 *
 * Builder-style chaining:
 *
 *     NSIndexSet *hits =
 *         [[[[TTIOQuery queryOnIndex:run.spectrumIndex]
 *             withMsLevel:2]
 *             withRetentionTimeRange:[TTIOValueRange rangeWithMinimum:600 maximum:720]]
 *             withPrecursorMzRange:[TTIOValueRange rangeWithMinimum:500 maximum:550]]
 *             matchingIndices];
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.query.Query
 *   Java:   com.dtwthalion.tio.Query
 */
@interface TTIOQuery : NSObject

+ (instancetype)queryOnIndex:(TTIOSpectrumIndex *)index;

- (TTIOQuery *)withRetentionTimeRange:(TTIOValueRange *)range;
- (TTIOQuery *)withMsLevel:(uint8_t)level;
- (TTIOQuery *)withPolarity:(TTIOPolarity)polarity;
- (TTIOQuery *)withPrecursorMzRange:(TTIOValueRange *)range;
- (TTIOQuery *)withBasePeakIntensityAtLeast:(double)threshold;

- (NSIndexSet *)matchingIndices;

@end

#endif
