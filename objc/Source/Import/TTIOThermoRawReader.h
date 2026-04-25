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
 * Milestone 29 — Thermo RAW stub.
 *
 * Defines the public API for a future Thermo .raw reader. In v0.4 all
 * methods return nil / NO with an ``NSError`` containing guidance on the
 * Thermo RawFileReader SDK dependency. This stub exists so downstream
 * code can reference the class and compile against a stable interface
 * that will be fulfilled in a future release.
 *
 * API status: Stable (interface); v0.4 stub — delegation to
 * ThermoRawFileParser is a future milestone in ObjC.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.thermo_raw (M38 shipped; delegates to
 *           ThermoRawFileParser binary)
 *   Java:   com.dtwthalion.tio.importers.ThermoRawReader (M38 shipped;
 *           delegates to ThermoRawFileParser binary)
 */
@interface TTIOThermoRawReader : NSObject

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error;

@end

#endif
