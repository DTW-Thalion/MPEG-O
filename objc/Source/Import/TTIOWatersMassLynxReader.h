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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOWatersMassLynxReader.h</p>
 *
 * <p>Waters MassLynx <code>.raw</code> directory importer. Delegates
 * to the user-installed <code>masslynxraw</code> converter
 * (a proprietary Waters tool) via <code>NSTask</code>. Semantics
 * mirror <code>TTIOThermoRawReader</code>: the converter emits an
 * mzML in a temp directory, which is parsed via
 * <code>TTIOMzMLReader</code>. No Waters proprietary code is compiled
 * into <code>libTTIO</code>.</p>
 *
 * <p><strong>Binary resolution order:</strong></p>
 * <ol>
 *  <li>Explicit <code>converter</code> argument
 *      (when non-<code>nil</code>).</li>
 *  <li><code>MASSLYNXRAW</code> environment variable.</li>
 *  <li><code>masslynxraw</code> on <code>PATH</code> (native).</li>
 *  <li><code>MassLynxRaw.exe</code> on <code>PATH</code> &#8212;
 *      invoked via <code>mono</code>.</li>
 * </ol>
 *
 * <p>Waters <code>.raw</code> inputs are directories, not files.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.waters_masslynx</code><br/>
 * Java:
 * <code>global.thalion.ttio.importers.WatersMassLynxReader</code></p>
 */
@interface TTIOWatersMassLynxReader : NSObject

/**
 * Reads a Waters <code>.raw</code> directory using an explicit
 * converter binary.
 *
 * @param path      Path to the Waters <code>.raw</code> directory.
 * @param converter Path to the <code>masslynxraw</code> converter.
 * @param error     Out-parameter populated on failure.
 * @return The parsed dataset, or <code>nil</code> on failure.
 */
+ (TTIOSpectralDataset *)readFromDirectoryPath:(NSString *)path
                                       converter:(NSString *)converter
                                           error:(NSError **)error;

/**
 * Convenience variant that resolves the converter via the standard
 * resolution order described in the class summary.
 *
 * @param path  Path to the Waters <code>.raw</code> directory.
 * @param error Out-parameter populated on failure.
 * @return The parsed dataset, or <code>nil</code> on failure.
 */
+ (TTIOSpectralDataset *)readFromDirectoryPath:(NSString *)path
                                           error:(NSError **)error;

@end

#endif
