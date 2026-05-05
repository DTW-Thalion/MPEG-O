/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_BRUKER_TDF_READER_H
#define TTIO_BRUKER_TDF_READER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOBrukerTDFReader.h</p>
 *
 * <p>SQLite-level metadata snapshot of a Bruker timsTOF
 * <code>.d</code> directory &#8212; no binary extraction
 * required.</p>
 */
@interface TTIOBrukerTDFMetadata : NSObject
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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOBrukerTDFReader.h</p>
 *
 * <p>Bruker timsTOF <code>.d</code> directory importer.</p>
 *
 * <p>The <code>.d</code> directory holds two files:</p>
 *
 * <ul>
 *  <li><code>analysis.tdf</code> &#8212; a plain SQLite database with
 *      metadata tables (<code>Frames</code>,
 *      <code>GlobalMetadata</code>, <code>Properties</code>,
 *      <code>Precursors</code>, ...).</li>
 *  <li><code>analysis.tdf_bin</code> or
 *      <code>analysis.tdf_raw</code> &#8212; a binary blob with
 *      ZSTD-compressed frame data and a scan-to-ion index.</li>
 * </ul>
 *
 * <p>This ObjC reader consumes the SQLite metadata directly via
 * <code>libsqlite3</code> (already linked for
 * <code>TTIOSqliteProvider</code>). Binary frame decompression
 * delegates to the Python <code>ttio.importers.bruker_tdf_cli</code>
 * tool via <code>NSTask</code>, matching the Java
 * <code>BrukerTDFReader</code> pattern.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.bruker_tdf</code><br/>
 * Java:
 * <code>global.thalion.ttio.importers.BrukerTDFReader</code></p>
 */
@interface TTIOBrukerTDFReader : NSObject

/** Read metadata from a Bruker `.d` directory. No external tooling
 *  required. Returns nil with NSError on malformed input. */
+ (nullable TTIOBrukerTDFMetadata *)readMetadataAtPath:(NSString *)dDir
                                                   error:(NSError **)error;

/** Import a Bruker `.d` directory to an `.tio` file by delegating
 *  binary extraction to the Python `ttio.importers.bruker_tdf_cli`
 *  helper. The Python interpreter is resolved via
 *  `TTIO_PYTHON` env var → `python3` on `PATH` → `python`.
 *
 *  Returns YES on success; NO with an NSError populated on any
 *  subprocess failure. */
+ (BOOL)importFromPath:(NSString *)dDir
             toOutput:(NSString *)output
                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_BRUKER_TDF_READER_H */
