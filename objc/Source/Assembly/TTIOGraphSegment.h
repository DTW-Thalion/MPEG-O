/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_GRAPH_SEGMENT_H
#define TTIO_GRAPH_SEGMENT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Assembly/TTIOGraphSegment.h</p>
 *
 * <p>One GFA 1.x <code>S</code> record of an assembly graph (M98):
 * the segment name, its bases, and its optional tags kept verbatim.
 * Immutable value object.</p>
 *
 * <p>A GFA segment may omit its sequence (<code>*</code> in the
 * sequence column, the <code>.noseq</code> assembler variants);
 * <code>sequence</code> is nil in that case and any declared length
 * lives in the verbatim <code>tags</code> (<code>LN:i:</code>).</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.assembly.GraphSegment</code><br/>
 * Java: <code>global.thalion.ttio.assembly.GraphSegment</code></p>
 */
@interface TTIOGraphSegment : NSObject

/** Segment name (GFA column 2). */
@property (readonly, copy) NSString *name;

/** Segment bases as ASCII bytes, or nil when the GFA carried
 *  <code>*</code>. */
@property (readonly, copy, nullable) NSData *sequence;

/** The record's optional tags, tab-joined verbatim; empty string
 *  when the record has none. */
@property (readonly, copy) NSString *tags;

- (instancetype)initWithName:(NSString *)name
                    sequence:(nullable NSData *)sequence
                        tags:(NSString *)tags;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif
