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
 * SAX-based nmrML parser (v1.0+). Consumes an nmrML document and
 * produces:
 *
 *   - zero or more TTIOFreeInductionDecay objects (one per &lt;fidData&gt;)
 *   - an TTIOSpectralDataset with a single NMR acquisition run
 *     containing every parsed &lt;spectrum1D&gt; as an TTIONMRSpectrum
 *
 * Parsed elements:
 *   - &lt;acquisitionParameterSet&gt; / cvParam: spectrometer frequency
 *     (NMR:1000001), nucleus (NMR:1000002), number of scans
 *     (NMR:1000003), dwell time (NMR:1000004), sweep width
 *     (NMR:1400014)
 *   - &lt;fidData&gt;: base64-encoded float64 complex (interleaved real+imag)
 *   - &lt;spectrum1D&gt; with &lt;xAxis&gt;/&lt;yAxis&gt;/&lt;spectrumDataArray&gt;: base64
 *     chemical shift + intensity arrays
 *
 * Not thread-safe. Returns nil with NSError on malformed input.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.nmrml
 *   Java:   com.dtwthalion.ttio.importers.NmrMLReader
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

/** Last-parsed acquisition parameters (applies to all FIDs/spectra
 *  in the file since nmrML 1.0 assumes a single acquisition block). */
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
