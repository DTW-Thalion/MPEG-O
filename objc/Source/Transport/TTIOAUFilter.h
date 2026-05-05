/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_AU_FILTER_H
#define TTIO_AU_FILTER_H

#import <Foundation/Foundation.h>
#import "TTIOAccessUnit.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOAUFilter.h</p>
 *
 * <p>Server-side AccessUnit filter. Every predicate is
 * <code>NSNumber</code>- or <code>NSString</code>-wrapped so
 * <code>nil</code> means "no constraint". Genomic predicates
 * (<code>chromosome</code>, <code>positionMin</code>,
 * <code>positionMax</code>) exclude any AU whose
 * <code>spectrumClass</code> indicates a non-genomic
 * record.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.filters.AUFilter</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.AUFilter</code></p>
 */
@interface TTIOAUFilter : NSObject

@property (nonatomic, readonly, copy, nullable) NSNumber *rtMin;
@property (nonatomic, readonly, copy, nullable) NSNumber *rtMax;
@property (nonatomic, readonly, copy, nullable) NSNumber *msLevel;
@property (nonatomic, readonly, copy, nullable) NSNumber *precursorMzMin;
@property (nonatomic, readonly, copy, nullable) NSNumber *precursorMzMax;
@property (nonatomic, readonly, copy, nullable) NSNumber *polarity;
@property (nonatomic, readonly, copy, nullable) NSNumber *datasetId;
@property (nonatomic, readonly, copy, nullable) NSNumber *maxAU;

/** Genomic predicates. <code>chromosome</code> is exact-string match
 *  (no wildcard) and excludes any AU whose chromosome differs (an
 *  MS AU has <code>chromosome = ""</code>, so any non-nil
 *  chromosome filter excludes it). <code>positionMin</code> /
 *  <code>positionMax</code> are inclusive on both ends; either being
 *  non-nil also excludes any AU whose
 *  <code>spectrumClass != 5</code>. */
@property (nonatomic, readonly, copy, nullable) NSString *chromosome;
@property (nonatomic, readonly, copy, nullable) NSNumber *positionMin;
@property (nonatomic, readonly, copy, nullable) NSNumber *positionMax;

/** @return A filter with no constraints (matches everything). */
+ (instancetype)emptyFilter;

/**
 * Parses <code>{"type":"query","filters":{...}}</code> into a
 * filter.
 *
 * @param json The query JSON string.
 * @return A filter populated from the JSON, or an empty filter on
 *         malformed input.
 */
+ (instancetype)filterFromQueryJSON:(NSString *)json;

/**
 * Evaluates the filter against an AccessUnit + dataset id.
 *
 * @param au        AccessUnit candidate.
 * @param datasetId Dataset identifier of the enclosing run.
 * @return <code>YES</code> when every predicate matches.
 */
- (BOOL)matches:(TTIOAccessUnit *)au datasetId:(uint16_t)datasetId;

@end

NS_ASSUME_NONNULL_END

#endif
