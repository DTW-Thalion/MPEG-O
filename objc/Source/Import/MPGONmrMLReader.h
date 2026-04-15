/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_NMRML_READER_H
#define MPGO_NMRML_READER_H

#import <Foundation/Foundation.h>

@class MPGOSpectralDataset;
@class MPGOFreeInductionDecay;
@class MPGONMRSpectrum;

/**
 * SAX-based nmrML parser (v1.0+). Consumes an nmrML document and
 * produces:
 *
 *   - zero or more MPGOFreeInductionDecay objects (one per <fidData>)
 *   - an MPGOSpectralDataset with a single NMR acquisition run
 *     containing every parsed <spectrum1D> as an MPGONMRSpectrum
 *
 * Parsed elements:
 *   - <acquisitionParameterSet> / cvParam: spectrometer frequency
 *     (NMR:1000001), nucleus (NMR:1000002), number of scans
 *     (NMR:1000003), dwell time (NMR:1000004), sweep width
 *     (NMR:1400014)
 *   - <fidData>: base64-encoded float64 complex (interleaved real+imag)
 *   - <spectrum1D> with <xAxis>/<yAxis>/<spectrumDataArray>: base64
 *     chemical shift + intensity arrays
 *
 * Not thread-safe. Returns nil with NSError on malformed input.
 */
@interface MPGONmrMLReader : NSObject

+ (MPGOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;
+ (MPGOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;
+ (MPGOSpectralDataset *)readFromData:(NSData *)data
                                error:(NSError **)error;

/** Instance-returning variant exposing the parsed FIDs (the
 *  MPGOSpectralDataset holds only processed spectra). */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

@property (readonly, strong) MPGOSpectralDataset                  *dataset;
@property (readonly, copy)   NSArray<MPGOFreeInductionDecay *>    *fids;

/** Last-parsed acquisition parameters (applies to all FIDs/spectra
 *  in the file since nmrML 1.0 assumes a single acquisition block). */
@property (readonly) double   spectrometerFrequencyMHz;
@property (readonly, copy) NSString *nucleusType;
@property (readonly) NSUInteger numberOfScans;
@property (readonly) double   dwellTimeSeconds;
@property (readonly) double   sweepWidthPpm;

@end

extern NSString *const MPGONmrMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, MPGONmrMLReaderErrorCode) {
    MPGONmrMLReaderErrorParseFailed       = 1,
    MPGONmrMLReaderErrorBase64Failed      = 2,
    MPGONmrMLReaderErrorArrayLengthMismatch = 3,
};

#endif /* MPGO_NMRML_READER_H */
