/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_SPECTRAL_DATASET_ASSEMBLY_WRITE_H
#define TTIO_SPECTRAL_DATASET_ASSEMBLY_WRITE_H

#import "Dataset/TTIOSpectralDataset.h"
#import "Providers/TTIOStorageProtocols.h"

@class TTIOWrittenAssemblyGraph;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p>Assembly-graph persistence (M98, format-spec 11a). One graph is
 * stored at <code>/study/assembly_graphs/&lt;name&gt;/</code>:
 * <code>segments/records</code> + <code>segments/sequences</code>
 * (through the byte-channel codec stack: BASE_PACK when the alphabet
 * is ACGTN, RANS_ORDER1 otherwise), the <code>links</code> /
 * <code>paths</code> / <code>extras</code> / <code>line_index</code>
 * compounds, and the <code>@gfa_version</code> /
 * <code>@producer</code> / <code>@final_newline</code> attributes.
 * The parent group maintains <code>@_graph_names</code>.</p>
 */
@interface TTIOSpectralDataset (AssemblyWrite)

/**
 * Write one assembly graph under
 * <code>&lt;study&gt;/assembly_graphs/&lt;name&gt;/</code>, creating
 * the parent group when absent. Errors when a graph of that name
 * already exists.
 */
+ (BOOL)writeAssemblyGraph:(TTIOWrittenAssemblyGraph *)graph
                     named:(NSString *)name
              toStudyGroup:(id<TTIOStorageGroup>)study
                     error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif
