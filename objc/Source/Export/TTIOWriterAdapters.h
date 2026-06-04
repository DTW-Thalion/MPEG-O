/*
 * TTIOWriterAdapters.h
 * TTI-O Objective-C Implementation
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_WRITER_ADAPTERS_H
#define TTIO_WRITER_ADAPTERS_H

#import <Foundation/Foundation.h>
#import "Export/TTIOWriter.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Export/TTIOWriterAdapters.h</p>
 *
 * <p>The 8 per-format <code>TTIOWriter</code> adapters (OT6). Each adapter
 * serializes one layer of an <em>opened</em>
 * <code>TTIOSpectralDataset</code> to an output path, mirroring the merged
 * Java <code>global.thalion.ttio.exporters.writers.*Adapter</code> classes
 * and the Python <code>ttio.exporters.writers</code> behavior. The exporter
 * registry (OT7) dispatches through them.</p>
 *
 * <p>Run selection is shared via <code>TTIORunSelection</code>; the
 * read-side &#8594; write-side genomic conversion for BAM / CRAM goes
 * through <code>+[TTIORunSelection writtenFromGenomicRun:]</code>. The
 * error-message strings raised here are kept byte-identical to the Python
 * reference so cross-language error parity holds.</p>
 *
 * <ul>
 *  <li><strong>mzML</strong>: whole dataset,
 *      <code>zlibCompression:YES</code> (Java default).</li>
 *  <li><strong>mzTab</strong>: <code>ds.identifications</code> +
 *      <code>ds.quantifications</code>; version from
 *      <code>opts["dialect"]</code> (default <code>"1.0"</code>).</li>
 *  <li><strong>nmrML</strong>: NMR run, first spectrum; rejects a
 *      non-NMR spectrum with the Python error text.</li>
 *  <li><strong>imzML</strong>: <code>ds.msImage</code> (null-guarded);
 *      sibling <code>.ibd</code> by extension swap; mode from
 *      <code>opts["mode"]</code> (default <code>"continuous"</code>).</li>
 *  <li><strong>JCAMP-DX</strong>: analytical run, first spectrum
 *      dispatched to IR / Raman / UV-Vis with
 *      <code>opts["encoding"]</code> (default <code>"affn"</code>); rejects
 *      a non-vibrational spectrum with the Python error text.</li>
 *  <li><strong>ISA</strong>: <code>.json</code> output =&gt; ISA-JSON,
 *      else a directory-style ISA-Tab bundle.</li>
 *  <li><strong>BAM</strong>: genomic run -&gt; written run; sorted
 *      output with <code>ds.provenanceRecords</code>.</li>
 *  <li><strong>CRAM</strong>: requires <code>opts["reference"]</code>
 *      (Python error text when absent); reference-compressed.</li>
 * </ul>
 */

/** mzML adapter. opts: none (zlib compression always on). */
@interface TTIOMzMLWriterAdapter : NSObject <TTIOWriter>
@end

/** mzTab adapter. opts: <code>dialect</code> (default <code>"1.0"</code>). */
@interface TTIOMzTabWriterAdapter : NSObject <TTIOWriter>
@end

/** nmrML adapter. opts: none. */
@interface TTIONmrMLWriterAdapter : NSObject <TTIOWriter>
@end

/** imzML adapter. opts: <code>mode</code> (default
 *  <code>"continuous"</code>). */
@interface TTIOImzMLWriterAdapter : NSObject <TTIOWriter>
@end

/** JCAMP-DX adapter. opts: <code>encoding</code> (default
 *  <code>"affn"</code>; one of affn / pac / sqz / dif). */
@interface TTIOJcampDxWriterAdapter : NSObject <TTIOWriter>
@end

/** ISA adapter. opts: none (ISA-JSON vs ISA-Tab chosen by output suffix). */
@interface TTIOIsaWriterAdapter : NSObject <TTIOWriter>
@end

/** BAM adapter. opts: none. */
@interface TTIOBamWriterAdapter : NSObject <TTIOWriter>
@end

/** CRAM adapter. opts: <code>reference</code> (required; reference FASTA). */
@interface TTIOCramWriterAdapter : NSObject <TTIOWriter>
@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_WRITER_ADAPTERS_H */
