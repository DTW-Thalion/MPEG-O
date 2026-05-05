/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_NMRML_READER_H
#define TTIO_NMRML_READER_H

#import <Foundation/Foundation.h>

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

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;
+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;
+ (TTIOSpectralDataset *)readFromData:(NSData *)data
                                error:(NSError **)error;

/** Instance-returning variant exposing the parsed FIDs (the
 *  TTIOSpectralDataset holds only processed spectra). */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

@property (readonly, strong) TTIOSpectralDataset                  *dataset;
@property (readonly, copy)   NSArray<TTIOFreeInductionDecay *>    *fids;

/** Last-parsed acquisition parameters (apply to all FIDs/spectra
 *  in the file since nmrML assumes a single acquisition block). */
@property (readonly) double   spectrometerFrequencyMHz;
@property (readonly, copy) NSString *nucleusType;
@property (readonly) NSUInteger numberOfScans;
@property (readonly) double   dwellTimeSeconds;
@property (readonly) double   sweepWidthPpm;

@end

extern NSString *const TTIONmrMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, TTIONmrMLReaderErrorCode) {
    TTIONmrMLReaderErrorParseFailed       = 1,
    TTIONmrMLReaderErrorBase64Failed      = 2,
    TTIONmrMLReaderErrorArrayLengthMismatch = 3,
};

#endif /* TTIO_NMRML_READER_H */
