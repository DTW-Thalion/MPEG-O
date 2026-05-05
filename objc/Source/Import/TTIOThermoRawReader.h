/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_THERMO_RAW_READER_H
#define TTIO_THERMO_RAW_READER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOThermoRawReader.h</p>
 *
 * <p>Public Objective-C entry point for reading Thermo Fisher
 * <code>.raw</code> mass-spectrometry files into a
 * <code>TTIOSpectralDataset</code>. The interface is fixed; in the
 * current ObjC build all methods return <code>nil</code> /
 * <code>NO</code> with an <code>NSError</code> describing the missing
 * Thermo RawFileReader SDK dependency. Downstream code can therefore
 * link against the class today and gain real functionality once the
 * SDK delegation lands.</p>
 *
 * <p><strong>API status:</strong> Stable interface; ObjC delegation
 * to ThermoRawFileParser pending.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.thermo_raw</code> (delegates to the
 * ThermoRawFileParser binary)<br/>
 * Java: <code>global.thalion.ttio.importers.ThermoRawReader</code>
 * (delegates to the ThermoRawFileParser binary)</p>
 */
@interface TTIOThermoRawReader : NSObject

/**
 * Reads a Thermo <code>.raw</code> file and returns the resulting
 * dataset.
 *
 * @param path  Filesystem path to a Thermo <code>.raw</code> file.
 * @param error Out-parameter populated with an
 *              SDK-dependency-missing message in the current build.
 * @return The parsed dataset, or <code>nil</code> on failure.
 */
+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error;

@end

#endif
