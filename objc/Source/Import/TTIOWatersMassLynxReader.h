/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_WATERS_MASSLYNX_READER_H
#define TTIO_WATERS_MASSLYNX_READER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;

/**
 * Waters MassLynx ``.raw`` directory importer — v0.9 M63.
 *
 * Delegates to the user-installed ``masslynxraw`` converter
 * (proprietary Waters tool) via NSTask. Semantics mirror
 * :class:`TTIOThermoRawReader`: the converter emits an mzML in a
 * temp directory, which we parse via TTIOMzMLReader. No Waters
 * proprietary code is compiled into libTTIO.
 *
 * Binary resolution order:
 *   1. Explicit ``converter`` argument (non-nil).
 *   2. ``MASSLYNXRAW`` environment variable.
 *   3. ``masslynxraw`` on PATH (native).
 *   4. ``MassLynxRaw.exe`` on PATH — invoked via ``mono``.
 *
 * Waters ``.raw`` inputs are directories, not files.
 *
 * API status: Provisional (v0.9 M63).
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.waters_masslynx
 *   Java:   com.dtwthalion.ttio.importers.WatersMassLynxReader
 */
@interface TTIOWatersMassLynxReader : NSObject

+ (TTIOSpectralDataset *)readFromDirectoryPath:(NSString *)path
                                       converter:(NSString *)converter
                                           error:(NSError **)error;

+ (TTIOSpectralDataset *)readFromDirectoryPath:(NSString *)path
                                           error:(NSError **)error;

@end

#endif
