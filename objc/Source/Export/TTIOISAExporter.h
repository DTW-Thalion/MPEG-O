/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_ISA_EXPORTER_H
#define TTIO_ISA_EXPORTER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOISAExporter.h</p>
 *
 * <p>ISA-Tab / ISA-JSON exporter. Produces a bundle of UTF-8 text
 * files that describe a <code>TTIOSpectralDataset</code> in the ISA
 * (Investigation / Study / Assay) model. Four filenames are
 * emitted:</p>
 *
 * <ul>
 *  <li><code>i_investigation.txt</code> &#8212; one row per
 *      Investigation metadata field.</li>
 *  <li><code>s_study.txt</code> &#8212; one row per sample (=
 *      acquisition run).</li>
 *  <li><code>a_assay_ms.txt</code> &#8212; one row per assay (=
 *      acquisition run).</li>
 *  <li><code>investigation.json</code> &#8212; ISA-JSON (single file
 *      per investigation).</li>
 * </ul>
 *
 * <p><strong>Mapping:</strong></p>
 * <ul>
 *  <li><code>dataset.title</code> &#8594; Investigation Title /
 *      Study Title.</li>
 *  <li><code>dataset.isaInvestigationId</code> &#8594; Investigation
 *      Identifier.</li>
 *  <li>Each <code>TTIOAcquisitionRun</code> &#8594; one Study sample
 *      + one Assay row.</li>
 *  <li><code>InstrumentConfig</code> &#8594; Assay technology
 *      platform / model.</li>
 *  <li>Provenance chain &#8594; Protocol REF / Parameter Value
 *      cells.</li>
 *  <li>Chromatograms &#8594; Derived Data File cells (names
 *      only).</li>
 * </ul>
 *
 * <p>The Python side lives in <code>ttio.exporters.isa</code> and
 * produces byte-identical output for the same input. This is verified
 * by the cross-language parity tests.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.isa</code><br/>
 * Java:
 * <code>global.thalion.ttio.exporters.ISAExporter</code></p>
 */
@interface TTIOISAExporter : NSObject

/**
 * Build the bundle as an in-memory map ``{filename: NSData}``. The keys
 * are the four filenames above; the values are UTF-8-encoded bodies
 * suitable for writing directly to disk.
 */
+ (NSDictionary<NSString *, NSData *> *)bundleForDataset:(TTIOSpectralDataset *)dataset
                                                    error:(NSError **)error;

/**
 * Convenience wrapper that writes ``bundleForDataset:`` into
 * ``directoryPath`` (creating it on demand). Returns NO on any I/O
 * failure.
 */
+ (BOOL)writeBundleForDataset:(TTIOSpectralDataset *)dataset
                  toDirectory:(NSString *)directoryPath
                        error:(NSError **)error;

@end

#endif /* TTIO_ISA_EXPORTER_H */
