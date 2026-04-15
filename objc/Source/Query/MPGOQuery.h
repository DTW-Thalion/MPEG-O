#ifndef MPGO_QUERY_H
#define MPGO_QUERY_H

#import <Foundation/Foundation.h>
#import "ValueClasses/MPGOEnums.h"

@class MPGOSpectrumIndex;
@class MPGOValueRange;

/**
 * Compressed-domain query against an MPGOSpectrumIndex. Predicates are
 * combined with AND (intersection). The query operates entirely on the
 * in-memory index arrays — signal-channel datasets are never opened, so
 * a 10k-spectrum scan completes in under a millisecond and never touches
 * the encrypted intensity stream.
 *
 * Builder-style chaining:
 *
 *     NSIndexSet *hits =
 *         [[[[MPGOQuery queryOnIndex:run.spectrumIndex]
 *             withMsLevel:2]
 *             withRetentionTimeRange:[MPGOValueRange rangeWithMinimum:600 maximum:720]]
 *             withPrecursorMzRange:[MPGOValueRange rangeWithMinimum:500 maximum:550]]
 *             matchingIndices];
 */
@interface MPGOQuery : NSObject

+ (instancetype)queryOnIndex:(MPGOSpectrumIndex *)index;

- (MPGOQuery *)withRetentionTimeRange:(MPGOValueRange *)range;
- (MPGOQuery *)withMsLevel:(uint8_t)level;
- (MPGOQuery *)withPolarity:(MPGOPolarity)polarity;
- (MPGOQuery *)withPrecursorMzRange:(MPGOValueRange *)range;
- (MPGOQuery *)withBasePeakIntensityAtLeast:(double)threshold;

- (NSIndexSet *)matchingIndices;

@end

#endif
