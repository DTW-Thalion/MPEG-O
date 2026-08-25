/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_GRAPH_LINK_H
#define TTIO_GRAPH_LINK_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Assembly/TTIOGraphLink.h</p>
 *
 * <p>One GFA 1.x <code>L</code> record (M98): an overlap edge
 * between two oriented segments. Orientations are the verbatim
 * <code>+</code> / <code>-</code> column strings; <code>overlap</code>
 * is the verbatim CIGAR column (may be <code>*</code>). Immutable
 * value object.</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.assembly.GraphLink</code><br/>
 * Java: <code>global.thalion.ttio.assembly.GraphLink</code></p>
 */
@interface TTIOGraphLink : NSObject

@property (readonly, copy) NSString *fromSegment;
@property (readonly, copy) NSString *fromOrient;
@property (readonly, copy) NSString *toSegment;
@property (readonly, copy) NSString *toOrient;
/** Overlap CIGAR column, verbatim (<code>*</code> allowed). */
@property (readonly, copy) NSString *overlap;
/** Optional tags, tab-joined verbatim; empty when none. */
@property (readonly, copy) NSString *tags;

- (instancetype)initWithFromSegment:(NSString *)fromSegment
                         fromOrient:(NSString *)fromOrient
                          toSegment:(NSString *)toSegment
                           toOrient:(NSString *)toOrient
                            overlap:(NSString *)overlap
                               tags:(NSString *)tags;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif
