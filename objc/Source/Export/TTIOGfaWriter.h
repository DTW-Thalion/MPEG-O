/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_GFA_WRITER_H
#define TTIO_GFA_WRITER_H

#import <Foundation/Foundation.h>

@class TTIOWrittenAssemblyGraph;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Export/TTIOGfaWriter.h</p>
 *
 * <p>GFA 1.x emitter (M98): the inverse of
 * <code>TTIOGfaReader</code>. Replays the graph's line index in file
 * order, re-serialising S/L/P records from their tables and emitting
 * <code>extras</code> verbatim, so a graph parsed from a producer's
 * file reproduces it byte for byte.</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.gfa.GfaWriter</code><br/>
 * Java: <code>global.thalion.ttio.exporters.GfaWriter</code></p>
 */
@interface TTIOGfaWriter : NSObject

/** The graph as GFA bytes. */
+ (NSData *)dataForGraph:(TTIOWrittenAssemblyGraph *)graph;

/** Write the graph to <code>path</code> as GFA. */
+ (BOOL)writeGraph:(TTIOWrittenAssemblyGraph *)graph
            toPath:(NSString *)path
             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
