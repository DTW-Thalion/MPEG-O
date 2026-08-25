/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_ASSEMBLY_GRAPH_H
#define TTIO_ASSEMBLY_GRAPH_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"

@class TTIOWrittenAssemblyGraph;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Assembly/TTIOAssemblyGraph.h</p>
 *
 * <p>Read-side handle over one stored assembly graph at
 * <code>/study/assembly_graphs/&lt;name&gt;/</code> (M98,
 * format-spec 11a). Run-level attributes load at open; the S/L/P
 * tables, extras, and line index materialise on the first
 * <code>-writtenGraphWithError:</code> call and are cached for the
 * handle's lifetime.</p>
 *
 * <p><code>-gfaDataWithError:</code> re-emits the graph as GFA; for
 * a graph written from <code>TTIOGfaReader</code> output the bytes
 * equal the original file.</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.assembly.AssemblyGraph</code><br/>
 * Java: <code>global.thalion.ttio.assembly.AssemblyGraph</code></p>
 */
@interface TTIOAssemblyGraph : NSObject

/** Graph name (the child group name). */
@property (readonly, copy) NSString *name;

/** The <code>@gfa_version</code> attribute. */
@property (readonly, copy) NSString *gfaVersion;

/** The <code>@producer</code> attribute. */
@property (readonly, copy) NSString *producer;

/** Whether the source GFA ended in a newline. */
@property (readonly) BOOL finalNewline;

/** Open the graph stored in <code>group</code>. Returns nil with
 *  <code>*error</code> set when the layout is malformed. */
+ (nullable instancetype)openFromGroup:(id<TTIOStorageGroup>)group
                                  name:(NSString *)name
                                 error:(NSError **)error;

/** Materialise the full graph (cached). */
- (nullable TTIOWrittenAssemblyGraph *)writtenGraphWithError:(NSError **)error;

/** The graph re-emitted as GFA bytes. */
- (nullable NSData *)gfaDataWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
