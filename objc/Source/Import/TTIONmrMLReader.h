/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_NMRML_READER_H
#define TTIO_NMRML_READER_H

#import <Foundation/Foundation.h>
#import "Core/TTIOProgressSink.h"

@class TTIOSpectralDataset;
@class TTIOFreeInductionDecay;
@class TTIONMRSpectrum;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIONmrMLReader.h</p>
 *
 * <p>SAX-based nmrML parser. Consumes an nmrML document and
 * produces:</p>
 *
 * <ul>
 *  <li>zero or more <code>TTIOFreeInductionDecay</code> objects (one
 *      per <code>&lt;fidData&gt;</code>);</li>
 *  <li>a <code>TTIOSpectralDataset</code> with a single NMR
 *      acquisition run containing every parsed
 *      <code>&lt;spectrum1D&gt;</code> as an
 *      <code>TTIONMRSpectrum</code>.</li>
 * </ul>
 *
 * <p><strong>Parsed elements:</strong></p>
 * <ul>
 *  <li><code>&lt;acquisitionParameterSet&gt;</code> / cvParam:
 *      spectrometer frequency (NMR:1000001), nucleus (NMR:1000002),
 *      number of scans (NMR:1000003), dwell time (NMR:1000004),
 *      sweep width (NMR:1400014).</li>
 *  <li><code>&lt;fidData&gt;</code>: base64-encoded float64 complex
 *      (interleaved real + imag).</li>
 *  <li><code>&lt;spectrum1D&gt;</code> with
 *      <code>&lt;xAxis&gt;</code> /
 *      <code>&lt;yAxis&gt;</code> /
 *      <code>&lt;spectrumDataArray&gt;</code>: base64 chemical shift
 *      + intensity arrays.</li>
 * </ul>
 *
 * <p>Not thread-safe. Returns <code>nil</code> with
 * <code>NSError</code> on malformed input.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.nmrml</code><br/>
 * Java: <code>global.thalion.ttio.importers.NmrMLReader</code></p>
 */
@interface TTIONmrMLReader : NSObject

/**
 * Parse an nmrML file from a filesystem path.
 *
 * @param path   Filesystem path to the nmrML document.
 * @param error  On failure, populated with an ``NSError`` in
 *               ``TTIONmrMLReaderErrorDomain``. May be ``NULL``.
 * @return The populated dataset on success; ``nil`` on parse
 *         failure or IO error.
 */
+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;

/**
 * Parse an nmrML file referenced by an ``NSURL``.
 *
 * @param url    File or data URL pointing at the nmrML document.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return The populated dataset on success; ``nil`` on failure.
 */
+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;

/**
 * Parse an nmrML document from an in-memory byte buffer.
 *
 * @param data   Raw nmrML XML bytes.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return The populated dataset on success; ``nil`` on failure.
 */
+ (TTIOSpectralDataset *)readFromData:(NSData *)data
                                error:(NSError **)error;

/** Progress-aware overload. nmrML is a single-spectrum format so the
 *  block fires exactly once with {@code (1, 1)} after the parse
 *  completes. Pass nil for {@code progress} to skip the callback. */
+ (nullable TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                          progress:(nullable TTIOProgressBlock)progress
                                             error:(NSError **)error;

/**
 * Parse an nmrML file and return a reader instance that exposes the
 * parsed FIDs in addition to the dataset.
 *
 * @param path   Filesystem path to the nmrML document.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return A reader carrying the populated ``dataset`` and ``fids``
 *         properties; ``nil`` on failure.
 */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;

/**
 * Parse an nmrML document from an in-memory byte buffer and return
 * a reader instance that exposes the parsed FIDs.
 *
 * @param data   Raw nmrML XML bytes.
 * @param error  On failure, populated with an ``NSError``. May be
 *               ``NULL``.
 * @return A reader carrying the populated ``dataset`` and ``fids``
 *         properties; ``nil`` on failure.
 */
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

/**
 * Progress-aware overload of {@link parseFilePath:error:}.
 *
 * @param path      Filesystem path to the nmrML document.
 * @param progress  Optional block fired once with ``(1, 1)`` after
 *                  parse completes. May be ``nil``.
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
 * @param data      Raw nmrML XML bytes.
 * @param progress  Optional progress block. May be ``nil``.
 * @param error     On failure, populated with an ``NSError``. May be
 *                  ``NULL``.
 * @return A reader on success; ``nil`` on failure.
 */
+ (nullable instancetype)parseData:(NSData *)data
                          progress:(nullable TTIOProgressBlock)progress
                             error:(NSError **)error;

@property (readonly, strong) TTIOSpectralDataset                  *dataset;
@property (readonly, copy)   NSArray<TTIOFreeInductionDecay *>    *fids;

/** Last-parsed acquisition parameters (apply to all FIDs/spectra
 *  in the file since nmrML assumes a single acquisition block). */
@property (readonly) double   spectrometerFrequencyMHz;
@property (readonly, copy) NSString *nucleusType;
@property (readonly) NSUInteger numberOfScans;
@property (readonly) double   dwellTimeSeconds;
@property (readonly) double   sweepWidthPpm;

/** Deinterleaved real / imag sample arrays from the source's
 *  <code>&lt;fidData byteFormat="complex128"&gt;</code> stream.
 *  Empty NSData on FID-less files or when the source declared a
 *  non-complex128 byte format. Mirrors Python
 *  <code>ImportResult.fid_real</code> / <code>fid_imag</code>
 *  (added 2026-05-05) so cross-language consumers see the same
 *  surface. Each entry is a packed <code>float64</code> array. */
@property (readonly, copy) NSData *fidReal;
@property (readonly, copy) NSData *fidImag;

@end

extern NSString *const TTIONmrMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, TTIONmrMLReaderErrorCode) {
    TTIONmrMLReaderErrorParseFailed       = 1,
    TTIONmrMLReaderErrorBase64Failed      = 2,
    TTIONmrMLReaderErrorArrayLengthMismatch = 3,
};

#endif /* TTIO_NMRML_READER_H */
