/*
 * TTIOAUFilter — v0.10 M68.5. Parallel to Python
 * ttio.transport.filters.AUFilter and Java
 * global.thalion.ttio.transport.AUFilter.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_AU_FILTER_H
#define TTIO_AU_FILTER_H

#import <Foundation/Foundation.h>
#import "TTIOAccessUnit.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOAUFilter : NSObject

/** NSNumber-wrapped so nil means "no constraint". */
@property (nonatomic, readonly, copy, nullable) NSNumber *rtMin;
@property (nonatomic, readonly, copy, nullable) NSNumber *rtMax;
@property (nonatomic, readonly, copy, nullable) NSNumber *msLevel;
@property (nonatomic, readonly, copy, nullable) NSNumber *precursorMzMin;
@property (nonatomic, readonly, copy, nullable) NSNumber *precursorMzMax;
@property (nonatomic, readonly, copy, nullable) NSNumber *polarity;
@property (nonatomic, readonly, copy, nullable) NSNumber *datasetId;
@property (nonatomic, readonly, copy, nullable) NSNumber *maxAU;

// M89.3: genomic predicates. ``chromosome`` is exact-string match
// (no wildcard) and excludes any AU whose chromosome differs (an MS
// AU has chromosome="" so it's excluded by any non-nil chromosome
// filter). ``positionMin`` / ``positionMax`` are inclusive on both
// ends; either being non-nil also excludes any AU whose
// spectrumClass != 5 (MS AUs have no notion of position).
@property (nonatomic, readonly, copy, nullable) NSString *chromosome;
@property (nonatomic, readonly, copy, nullable) NSNumber *positionMin;
@property (nonatomic, readonly, copy, nullable) NSNumber *positionMax;

+ (instancetype)emptyFilter;

/** Parse ``{"type":"query","filters":{...}}`` into an TTIOAUFilter. */
+ (instancetype)filterFromQueryJSON:(NSString *)json;

/** Evaluate against an AccessUnit + dataset id. */
- (BOOL)matches:(TTIOAccessUnit *)au datasetId:(uint16_t)datasetId;

@end

NS_ASSUME_NONNULL_END

#endif
