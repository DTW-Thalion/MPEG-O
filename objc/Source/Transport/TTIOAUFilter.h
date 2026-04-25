/*
 * TTIOAUFilter — v0.10 M68.5. Parallel to Python
 * ttio.transport.filters.AUFilter and Java
 * com.dtwthalion.ttio.transport.AUFilter.
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

+ (instancetype)emptyFilter;

/** Parse ``{"type":"query","filters":{...}}`` into an TTIOAUFilter. */
+ (instancetype)filterFromQueryJSON:(NSString *)json;

/** Evaluate against an AccessUnit + dataset id. */
- (BOOL)matches:(TTIOAccessUnit *)au datasetId:(uint16_t)datasetId;

@end

NS_ASSUME_NONNULL_END

#endif
