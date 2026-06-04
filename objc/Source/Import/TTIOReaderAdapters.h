/*
 * TTIOReaderAdapters.h
 * TTI-O Objective-C Implementation
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_READER_ADAPTERS_H
#define TTIO_READER_ADAPTERS_H

#import <Foundation/Foundation.h>
#import "Import/TTIOReader.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Import/TTIOReaderAdapters.h</p>
 *
 * <p>The 11 per-format <code>TTIOReader</code> adapters (OT5). Each
 * adapter normalizes one importer into a
 * <code>TTIOImportedDataset</code> draft, mirroring the merged Java
 * <code>global.thalion.ttio.importers.readers.*Adapter</code> classes
 * and the Python <code>ttio.importers.readers</code> behavior. The
 * importer registry (OT7) dispatches through them.</p>
 *
 * <p><strong>Write model.</strong> Adapters never write a
 * <code>.tio</code> in <code>-readInputs:options:progress:error:</code>;
 * the write happens at <code>-[TTIOImportedDataset writeToPath:error:]</code>:</p>
 *
 * <ul>
 *  <li><strong>Dataset-returning</strong> (mzML / nmrML / Waters /
 *      Thermo): the adapter parses a <code>TTIOSpectralDataset</code>
 *      and installs a write-through delegate that writes the parsed
 *      dataset via <code>-writeToFilePath:error:</code>.</li>
 *  <li><strong>imzML</strong>: projects the pixel spectra into a
 *      <code>TTIOMSImage</code> cube (set on <code>draft.msImage</code>)
 *      and installs an image write-through delegate. NEW capability —
 *      imzML import now produces a <code>.tio</code> in ObjC.</li>
 *  <li><strong>mzTab</strong>: copies identifications + quantifications
 *      into the draft (no run; non-delegate writeMinimal path).</li>
 *  <li><strong>JCAMP-DX</strong>: wraps the single parsed spectrum into
 *      a one-spectrum <code>TTIOAcquisitionRun</code> and installs a
 *      write-through delegate that writes that run's dataset.</li>
 *  <li><strong>Bruker</strong>: returns the OT4 write-through draft
 *      (subprocess runs at write time).</li>
 *  <li><strong>BAM / SAM / CRAM</strong>: builds a
 *      <code>TTIOWrittenGenomicRun</code> into
 *      <code>draft.genomicRuns</code> (non-delegate writeMinimal
 *      path).</li>
 * </ul>
 */

/** mzML adapter. opts: none. */
@interface TTIOMzMLReaderAdapter : NSObject <TTIOReader>
@end

/** mzTab adapter. opts: none. */
@interface TTIOMzTabReaderAdapter : NSObject <TTIOReader>
@end

/** imzML adapter. opts: <code>ibd</code> (path to the <code>.ibd</code>;
 *  else <code>inputs[1]</code>; else sibling). Continuous mode only. */
@interface TTIOImzMLReaderAdapter : NSObject <TTIOReader>
@end

/** nmrML adapter. opts: none. */
@interface TTIONmrMLReaderAdapter : NSObject <TTIOReader>
@end

/** Thermo <code>.raw</code> adapter. opts: none. */
@interface TTIOThermoRawReaderAdapter : NSObject <TTIOReader>
@end

/** Waters MassLynx <code>.raw</code> directory adapter. opts: none. */
@interface TTIOWatersMassLynxReaderAdapter : NSObject <TTIOReader>
@end

/** JCAMP-DX adapter. opts: <code>name</code> (run name, default
 *  <code>spectrum_0001</code>). */
@interface TTIOJcampDxReaderAdapter : NSObject <TTIOReader>
@end

/** Bruker timsTOF <code>.d</code> adapter. opts: none. */
@interface TTIOBrukerReaderAdapter : NSObject <TTIOReader>
@end

/** BAM adapter. opts: <code>name</code> (default
 *  <code>genomic_0001</code>), <code>region</code>, <code>sample</code>. */
@interface TTIOBamReaderAdapter : NSObject <TTIOReader>
@end

/** SAM adapter. Same opts as the BAM adapter. */
@interface TTIOSamReaderAdapter : NSObject <TTIOReader>
@end

/** CRAM adapter. Requires <code>reference</code> (reference FASTA);
 *  same <code>name</code> / <code>region</code> / <code>sample</code>
 *  opts as the BAM adapter. */
@interface TTIOCramReaderAdapter : NSObject <TTIOReader>
@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_READER_ADAPTERS_H */
