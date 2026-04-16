/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_ISA_EXPORTER_H
#define MPGO_ISA_EXPORTER_H

#import <Foundation/Foundation.h>

@class MPGOSpectralDataset;

/**
 * Milestone 27 — ISA-Tab / ISA-JSON exporter.
 *
 * Produces a bundle of UTF-8 text files that describe an
 * :class:`MPGOSpectralDataset` in the ISA (Investigation/Study/Assay)
 * model. Four filenames are emitted:
 *
 *   i_investigation.txt   — one row per Investigation metadata field
 *   s_study.txt           — one row per sample (= acquisition run)
 *   a_assay_ms.txt        — one row per assay (= acquisition run)
 *   investigation.json    — ISA-JSON (single file per investigation)
 *
 * Mapping:
 *   dataset.title            -> Investigation Title / Study Title
 *   dataset.isaInvestigationId -> Investigation Identifier
 *   each MPGOAcquisitionRun  -> one Study sample + one Assay row
 *   InstrumentConfig         -> Assay technology platform / model
 *   provenance chain         -> Protocol REF / Parameter Value cells
 *   chromatograms            -> Derived Data File cells (names only)
 *
 * The Python side lives in ``mpeg_o.exporters.isa`` and produces
 * byte-identical output for the same input. This is verified by the
 * M27 cross-language parity tests.
 */
@interface MPGOISAExporter : NSObject

/**
 * Build the bundle as an in-memory map ``{filename: NSData}``. The keys
 * are the four filenames above; the values are UTF-8-encoded bodies
 * suitable for writing directly to disk.
 */
+ (NSDictionary<NSString *, NSData *> *)bundleForDataset:(MPGOSpectralDataset *)dataset
                                                    error:(NSError **)error;

/**
 * Convenience wrapper that writes ``bundleForDataset:`` into
 * ``directoryPath`` (creating it on demand). Returns NO on any I/O
 * failure.
 */
+ (BOOL)writeBundleForDataset:(MPGOSpectralDataset *)dataset
                  toDirectory:(NSString *)directoryPath
                        error:(NSError **)error;

@end

#endif /* MPGO_ISA_EXPORTER_H */
