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
 * ``TTIOMzMLWriter`` emits an ``indexedmzML`` file from a
 * :class:`TTIOSpectralDataset`. The output is the ObjC side of the M19
 * mzML export pass; the Python side lives in ``ttio.exporters.mzml``
 * and mirrors the XML structure produced here.
 *
 * The current scope (v0.3 M19) covers:
 *
 * - ``TTIOMassSpectrum`` runs (``mz`` + ``intensity`` channels)
 * - Optional zlib compression of binary data arrays
 * - ``indexedmzML`` wrapper with byte-correct offsets per spectrum
 * - Minimal but conformant ``cvList``, ``fileDescription``,
 *   ``softwareList``, ``instrumentConfigurationList``, and
 *   ``dataProcessingList`` scaffolding so the output re-parses with
 *   :class:`TTIOMzMLReader` and pwiz tools.
 *
 * NMR runs, chromatograms, MSImage cubes, and referenceable param
 * groups are deliberately out of scope for M19; extending the writer
 * for them is a straightforward follow-up.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.exporters.mzml
 *   Java:   com.dtwthalion.ttio.exporters.MzMLWriter
 */
@interface TTIOMzMLWriter : NSObject

/**
 * Serialize ``dataset`` to an in-memory ``NSData`` containing indexed
 * mzML. The caller chooses the first MS run whose spectra are
 * ``TTIOMassSpectrum`` instances; additional runs are ignored. The
 * returned data is always ``UTF-8``.
 *
 * When ``zlibCompression`` is YES the m/z and intensity arrays are
 * zlib-compressed before base64 encoding and annotated with
 * ``MS:1000574``.
 */
+ (NSData *)dataForDataset:(TTIOSpectralDataset *)dataset
           zlibCompression:(BOOL)zlibCompression
                     error:(NSError **)error;

/**
 * Convenience wrapper that writes ``dataForDataset:...`` to a file
 * path. Overwrites an existing file atomically.
 */
+ (BOOL)writeDataset:(TTIOSpectralDataset *)dataset
              toPath:(NSString *)path
     zlibCompression:(BOOL)zlibCompression
                error:(NSError **)error;

@end

#endif /* TTIO_MZML_WRITER_H */
