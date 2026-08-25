/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_WRITTEN_ASSEMBLY_GRAPH_H
#define TTIO_WRITTEN_ASSEMBLY_GRAPH_H

#import <Foundation/Foundation.h>

@class TTIOGraphSegment;
@class TTIOGraphLink;
@class TTIOGraphPath;

NS_ASSUME_NONNULL_BEGIN

/** Line-type codes of the M98 <code>line_index</code> table
 *  (format-spec 11a): the file-order interleaving of a GFA's
 *  records. <code>Extra</code> covers every non-S/L/P line (headers,
 *  containments, comments, producer extensions), stored verbatim. */
typedef NS_ENUM(uint32_t, TTIOGfaLineType) {
    TTIOGfaLineTypeSegment = 0,
    TTIOGfaLineTypeLink    = 1,
    TTIOGfaLineTypePath    = 2,
    TTIOGfaLineTypeExtra   = 3,
};

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Assembly/TTIOWrittenAssemblyGraph.h</p>
 *
 * <p>Write-side container for one assembly graph (M98): the parsed
 * S/L/P tables, every other line verbatim, and the file-order line
 * index that lets <code>TTIOGfaWriter</code> re-emit the producer's
 * GFA byte for byte. Produced by <code>TTIOGfaReader</code> or built
 * directly; consumed by
 * <code>+[TTIOSpectralDataset writeMinimalToPath:...assemblyGraphs:]</code>.</p>
 *
 * <p><code>lineTypes</code> is a uint32 buffer of
 * <code>TTIOGfaLineType</code> values and <code>lineRows</code> a
 * parallel uint64 buffer of row indices into the table the type
 * selects. Both have one entry per line of the source GFA.</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.assembly.WrittenAssemblyGraph</code><br/>
 * Java: <code>global.thalion.ttio.assembly.WrittenAssemblyGraph</code></p>
 */
@interface TTIOWrittenAssemblyGraph : NSObject

/** GFA version string stored as <code>@gfa_version</code>
 *  (<code>"1.0"</code> unless the caller knows better). */
@property (readonly, copy) NSString *gfaVersion;

/** Producer tag stored as <code>@producer</code> (e.g.
 *  <code>"hifiasm 0.25.0"</code>; empty when unknown). */
@property (readonly, copy) NSString *producer;

/** Whether the source GFA ended in a newline. */
@property (readonly) BOOL finalNewline;

@property (readonly, copy) NSArray<TTIOGraphSegment *> *segments;
@property (readonly, copy) NSArray<TTIOGraphLink *> *links;
@property (readonly, copy) NSArray<TTIOGraphPath *> *paths;

/** Verbatim non-S/L/P lines in first-seen order. */
@property (readonly, copy) NSArray<NSString *> *extras;

/** uint32 <code>TTIOGfaLineType</code> per source line. */
@property (readonly, copy) NSData *lineTypes;

/** uint64 row index per source line, parallel to
 *  <code>lineTypes</code>. */
@property (readonly, copy) NSData *lineRows;

/** Number of source lines (derived from <code>lineTypes</code>). */
@property (readonly) NSUInteger lineCount;

/**
 * Designated initialiser. Validates that the line index is parallel
 * and that every row index is in range for its table; raises
 * <code>NSInvalidArgumentException</code> otherwise.
 */
- (instancetype)initWithGfaVersion:(NSString *)gfaVersion
                          producer:(NSString *)producer
                      finalNewline:(BOOL)finalNewline
                          segments:(NSArray<TTIOGraphSegment *> *)segments
                             links:(NSArray<TTIOGraphLink *> *)links
                             paths:(NSArray<TTIOGraphPath *> *)paths
                            extras:(NSArray<NSString *> *)extras
                         lineTypes:(NSData *)lineTypes
                          lineRows:(NSData *)lineRows;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif
