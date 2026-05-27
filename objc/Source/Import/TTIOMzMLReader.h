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

/** One-shot class methods. Return only the dataset. */
+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;
+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;
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

/** Instance-returning variants that also expose chromatograms and
 *  parsed provenance separately, since v0.1 TTIOSpectralDataset has
 *  no chromatogram slot. Returns nil on failure. */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

/** Progress-aware overloads of {@link parseFilePath:error:} +
 *  {@link parseData:error:}. */
+ (nullable instancetype)parseFilePath:(NSString *)path
                              progress:(nullable TTIOProgressBlock)progress
                                 error:(NSError **)error;
+ (nullable instancetype)parseData:(NSData *)data
                          progress:(nullable TTIOProgressBlock)progress
                             error:(NSError **)error;

@property (readonly, strong) TTIOSpectralDataset                *dataset;
@property (readonly, copy)   NSArray<TTIOChromatogram *>        *chromatograms;

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
