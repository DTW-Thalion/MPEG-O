/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_GRAPH_PATH_H
#define TTIO_GRAPH_PATH_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Assembly/TTIOGraphPath.h</p>
 *
 * <p>One GFA 1.x <code>P</code> record (M98): a named walk through
 * oriented segments. <code>segmentList</code> and
 * <code>overlaps</code> are the verbatim comma-separated GFA columns.
 * Immutable value object.</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.assembly.GraphPath</code><br/>
 * Java: <code>global.thalion.ttio.assembly.GraphPath</code></p>
 */
@interface TTIOGraphPath : NSObject

@property (readonly, copy) NSString *name;
/** Comma-separated oriented segment names, verbatim
 *  (e.g. <code>utg1+,utg2-</code>). */
@property (readonly, copy) NSString *segmentList;
/** Comma-separated overlap CIGARs, verbatim (<code>*</code> allowed). */
@property (readonly, copy) NSString *overlaps;
/** Optional tags, tab-joined verbatim; empty when none. */
@property (readonly, copy) NSString *tags;

- (instancetype)initWithName:(NSString *)name
                 segmentList:(NSString *)segmentList
                    overlaps:(NSString *)overlaps
                        tags:(NSString *)tags;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif
