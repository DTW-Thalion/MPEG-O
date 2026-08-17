/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_MZML_READER_H
#define TTIO_MZML_READER_H

#import <Foundation/Foundation.h>
#import "Core/TTIOProgressSink.h"

@class TTIOSpectralDataset;
@class TTIOChromatogram;
@class TTIOSpectralStreamSource;

NS_ASSUME_NONNULL_BEGIN

/** Emit-every-N cadence for {@link TTIOProgressBlock} callbacks
 *  during mzML parsing. Mirrors Java's
 *  {@code MzMLReader.PROGRESS_INTERVAL_SPECTRA}. */
FOUNDATION_EXPORT const NSUInteger TTIOMzMLReaderProgressIntervalSpectra;

NS_ASSUME_NONNULL_END

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOMzMLReader.h</p>
 *
 * <p>SAX-based mzML 1.1 parser. Consumes an mzML document and
 * produces a populated <code>TTIOSpectralDataset</code> containing
 * one <code>TTIOAcquisitionRun</code> per <code>&lt;run&gt;</code>
 * element. Chromatograms appear as extra spectra carrying the
 * <code>TTIOChromatogram</code> class tag.</p>
 *
 * <p><strong>What is parsed:</strong></p>
 * <ul>
 *  <li><code>&lt;spectrum&gt;</code> elements with cvParam-driven
 *      metadata (MS level, polarity, scan start time, scan window,
 *      precursor m/z &amp; charge).</li>
 *  <li><code>&lt;binaryDataArray&gt;</code> payloads decoded via
 *      <code>TTIOBase64</code>, typed via
 *      <code>TTIOCVTermMapper</code>, packaged as
 *      <code>TTIOSignalArray</code>.</li>
 *  <li><code>&lt;chromatogram&gt;</code> elements with time +
 *      intensity arrays.</li>
 *  <li><code>&lt;dataProcessing&gt;</code> as
 *      <code>TTIOProvenanceRecord</code> chain (best effort).</li>
 * </ul>
 *
 * <p><strong>What is ignored:</strong></p>
 * <ul>
 *  <li><code>spectrumRef</code> / <code>sourceFileRef</code>
 *      cross-references.</li>
 *  <li><code>softwareList</code> (captured as provenance agent names
 *      only).</li>
 *  <li><code>fileDescription</code> except for the list of source
 *      files.</li>
 * </ul>
 *
 * <p>On malformed input the reader returns <code>nil</code> and
 * populates <code>error</code> with a descriptive
 * <code>NSError</code> in the
 * <code>TTIOMzMLReaderErrorDomain</code>. Not thread-safe.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.mzml</code><br/>
 * Java: <code>global.thalion.ttio.importers.MzMLReader</code></p>
 */
@interface TTIOMzMLReader : NSObject

/**
 * Parse an mzML file from a filesystem path.
 *
 * @param path   Filesystem path to the mzML document.
 * @param error  On failure, populated with an ``NSError`` in
 *               ``TTIOMzMLReaderErrorDomain``. May be ``NULL``.
 * @return The populated dataset on success; ``nil`` on parse
 *         failure or IO error.
 */
+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;

/**
 * Parse an mzML file referenced by an ``NSURL``.
 *
 * @param url    File or data URL pointing at the mzML document.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return The populated dataset on success; ``nil`` on failure.
 */
+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;

/**
 * Parse an mzML document from an in-memory byte buffer.
 *
 * @param data   Raw mzML XML bytes.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return The populated dataset on success; ``nil`` on failure.
 */
+ (TTIOSpectralDataset *)readFromData:(NSData *)data
                                error:(NSError **)error;

/** Progress-aware overload of {@link readFromFilePath:error:}. Fires
 *  {@code progress(specsDone, -1)} every
 *  {@link TTIOMzMLReaderProgressIntervalSpectra} spectra during the
 *  parse phase and a final {@code progress(total, total)} once the
 *  spectrum count is known. Pass nil for {@code progress} to skip
 *  callbacks. */
+ (nullable TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                          progress:(nullable TTIOProgressBlock)progress
                                             error:(NSError **)error;

/**
 * Parse an mzML file and return a reader instance that exposes the
 * dataset plus the parsed chromatograms as a separate array.
 *
 * @param path   Filesystem path to the mzML document.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return A reader carrying the populated ``dataset`` and
 *         ``chromatograms`` properties; ``nil`` on failure.
 */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;

/**
 * Parse an mzML document from an in-memory byte buffer and return a
 * reader instance.
 *
 * @param data   Raw mzML XML bytes.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return A reader carrying the populated ``dataset`` and
 *         ``chromatograms`` properties; ``nil`` on failure.
 */
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

/**
 * Progress-aware overload of {@link parseFilePath:error:}.
 *
 * @param path      Filesystem path to the mzML document.
 * @param progress  Optional block fired every
 *                  {@link TTIOMzMLReaderProgressIntervalSpectra}
 *                  spectra with ``total = -1``, and once at the end
 *                  with the final count. May be ``nil``.
 * @param error     On failure, populated with an ``NSError``. May be
 *                  ``NULL``.
 * @return A reader on success; ``nil`` on failure.
 */
+ (nullable instancetype)parseFilePath:(NSString *)path
                              progress:(nullable TTIOProgressBlock)progress
                                 error:(NSError **)error;

/**
 * Progress-aware overload of {@link parseData:error:}.
 *
 * @param data      Raw mzML XML bytes.
 * @param progress  Optional block fired during the parse. May be
 *                  ``nil``.
 * @param error     On failure, populated with an ``NSError``. May be
 *                  ``NULL``.
 * @return A reader on success; ``nil`` on failure.
 */
+ (nullable instancetype)parseData:(NSData *)data
                          progress:(nullable TTIOProgressBlock)progress
                             error:(NSError **)error;

@property (readonly, strong) TTIOSpectralDataset                *dataset;
@property (readonly, copy)   NSArray<TTIOChromatogram *>        *chromatograms;

/** Spectra per streamed batch by default (4096). */
+ (NSUInteger)defaultBatchSpectra;

/**
 * The file as a TTIOSpectralStreamSource: the parser runs on a
 * background thread and hands spectra over in batches of
 * <code>batchSpectra</code> through a bounded queue, so the run is
 * written with bounded memory; the chromatograms follow once the parse
 * ends. Python: <code>MzMLReader.stream</code>; Java:
 * <code>MzMLReader.stream</code>.
 */
+ (TTIOSpectralStreamSource *)streamFromPath:(NSString *)path
                                     runName:(NSString *)runName
                                batchSpectra:(NSUInteger)batchSpectra
                                    progress:(nullable TTIOProgressBlock)progress;

@end

extern NSString *const TTIOMzMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, TTIOMzMLReaderErrorCode) {
    TTIOMzMLReaderErrorParseFailed       = 1,
    TTIOMzMLReaderErrorMissingSpectrumList = 2,
    TTIOMzMLReaderErrorArrayLengthMismatch = 3,
    TTIOMzMLReaderErrorBase64Failed      = 4,
    TTIOMzMLReaderErrorUnsupportedEncoding = 5
};

#endif /* TTIO_MZML_READER_H */
