/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_MZML_WRITER_H
#define TTIO_MZML_WRITER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;
@class TTIOAcquisitionRun;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOMzMLWriter.h</p>
 *
 * <p>Emits an <code>indexedmzML</code> file from a
 * <code>TTIOSpectralDataset</code>. The Python side lives in
 * <code>ttio.exporters.mzml</code> and mirrors the XML structure
 * produced here.</p>
 *
 * <p><strong>Current scope:</strong></p>
 * <ul>
 *  <li><code>TTIOMassSpectrum</code> runs
 *      (<code>mz</code> + <code>intensity</code> channels).</li>
 *  <li>Optional zlib compression of binary data arrays.</li>
 *  <li><code>indexedmzML</code> wrapper with byte-correct offsets
 *      per spectrum.</li>
 *  <li>Minimal but conformant <code>cvList</code>,
 *      <code>fileDescription</code>, <code>softwareList</code>,
 *      <code>instrumentConfigurationList</code>, and
 *      <code>dataProcessingList</code> scaffolding so the output
 *      re-parses with <code>TTIOMzMLReader</code> and pwiz
 *      tools.</li>
 * </ul>
 *
 * <p>NMR runs, chromatograms, MSImage cubes, and referenceable param
 * groups are deliberately out of scope; extending the writer for
 * them is a straightforward follow-up.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.mzml</code><br/>
 * Java: <code>global.thalion.ttio.exporters.MzMLWriter</code></p>
 */
@interface TTIOMzMLWriter : NSObject

/**
 * Serialises <code>dataset</code> to an in-memory
 * <code>NSData</code> containing indexed mzML. The first MS run
 * whose spectra are <code>TTIOMassSpectrum</code> instances is used;
 * additional runs are ignored. The returned data is always UTF-8.
 *
 * @param dataset         Dataset to serialise.
 * @param zlibCompression When <code>YES</code>, m/z and intensity
 *                        arrays are zlib-compressed before base64
 *                        encoding and annotated with
 *                        <code>MS:1000574</code>.
 * @param error           Out-parameter populated on failure.
 * @return UTF-8 mzML data, or <code>nil</code> on failure.
 */
+ (NSData *)dataForDataset:(TTIOSpectralDataset *)dataset
           zlibCompression:(BOOL)zlibCompression
                     error:(NSError **)error;

/**
 * Convenience wrapper that writes
 * <code>+dataForDataset:zlibCompression:error:</code> output to a
 * file path. Overwrites an existing file atomically.
 *
 * @param dataset         Dataset to serialise.
 * @param path            Destination path.
 * @param zlibCompression Whether to zlib-compress binary data
 *                        arrays.
 * @param error           Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeDataset:(TTIOSpectralDataset *)dataset
              toPath:(NSString *)path
     zlibCompression:(BOOL)zlibCompression
                error:(NSError **)error;

@end

#endif /* TTIO_MZML_WRITER_H */
