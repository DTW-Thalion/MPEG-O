/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_BRUKER_TDF_READER_H
#define MPGO_BRUKER_TDF_READER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** SQLite-level metadata snapshot — no binary extraction required. */
@interface MPGOBrukerTDFMetadata : NSObject
@property (nonatomic, readonly) NSInteger frameCount;
@property (nonatomic, readonly) NSInteger ms1FrameCount;
@property (nonatomic, readonly) NSInteger ms2FrameCount;
@property (nonatomic, readonly) double retentionTimeMin;
@property (nonatomic, readonly) double retentionTimeMax;
@property (nonatomic, readonly, copy) NSString *instrumentVendor;
@property (nonatomic, readonly, copy) NSString *instrumentModel;
@property (nonatomic, readonly, copy) NSString *acquisitionSoftware;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *properties;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *globalMetadata;
@end

/**
 * Bruker timsTOF `.d` importer — v0.8 M53.
 *
 * The `.d` directory holds two files:
 *
 *   - `analysis.tdf` — a plain SQLite database with metadata tables
 *     (`Frames`, `GlobalMetadata`, `Properties`, `Precursors`, ...).
 *   - `analysis.tdf_bin` or `analysis.tdf_raw` — a binary blob with
 *     ZSTD-compressed frame data and a scan-to-ion index.
 *
 * This ObjC reader consumes the SQLite metadata directly via
 * `libsqlite3` (already linked for MPGOSqliteProvider). Binary frame
 * decompression delegates to the Python
 * `mpeg_o.importers.bruker_tdf_cli` tool via `NSTask`, matching the
 * Java `BrukerTDFReader` pattern. A native port of the frame decoder
 * (ZSTD + Bruker's scan-to-ion index) is a v0.9 concern.
 *
 * API status: Provisional (v0.8 M53).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.importers.bruker_tdf
 *   Java:   com.dtwthalion.mpgo.importers.BrukerTDFReader
 */
@interface MPGOBrukerTDFReader : NSObject

/** Read metadata from a Bruker `.d` directory. No external tooling
 *  required. Returns nil with NSError on malformed input. */
+ (nullable MPGOBrukerTDFMetadata *)readMetadataAtPath:(NSString *)dDir
                                                   error:(NSError **)error;

/** Import a Bruker `.d` directory to an `.mpgo` file by delegating
 *  binary extraction to the Python `mpeg_o.importers.bruker_tdf_cli`
 *  helper. The Python interpreter is resolved via
 *  `MPGO_PYTHON` env var → `python3` on `PATH` → `python`.
 *
 *  Returns YES on success; NO with an NSError populated on any
 *  subprocess failure. */
+ (BOOL)importFromPath:(NSString *)dDir
             toOutput:(NSString *)output
                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif  /* MPGO_BRUKER_TDF_READER_H */
