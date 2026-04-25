/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_MZML_READER_H
#define TTIO_MZML_READER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;
@class TTIOChromatogram;

/**
 * SAX-based mzML 1.1 parser. Consumes an mzML document and produces a
 * populated TTIOSpectralDataset containing one TTIOAcquisitionRun per
 * &lt;run&gt; element. Chromatograms appear as extra spectra carrying the
 * TTIOChromatogram class tag.
 *
 * What is parsed:
 *   - &lt;spectrum&gt; elements with cvParam-driven metadata (MS level,
 *     polarity, scan start time, scan window, precursor m/z &amp; charge)
 *   - &lt;binaryDataArray&gt; payloads decoded via TTIOBase64, typed via
 *     TTIOCVTermMapper, packaged as TTIOSignalArray
 *   - &lt;chromatogram&gt; elements with time + intensity arrays
 *   - &lt;dataProcessing&gt; as TTIOProvenanceRecord chain (best-effort)
 *
 * What is ignored (v0.2):
 *   - spectrumRef / sourceFileRef cross-references
 *   - softwareList (captured as provenance agent names only)
 *   - fileDescription except for the list of source files
 *
 * On malformed input the reader returns nil and populates `error` with a
 * descriptive NSError in the `TTIOMzMLReaderErrorDomain`. Not thread-safe.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.mzml
 *   Java:   com.dtwthalion.ttio.importers.MzMLReader
 */
@interface TTIOMzMLReader : NSObject

/** One-shot class methods. Return only the dataset. */
+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;
+ (TTIOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;
+ (TTIOSpectralDataset *)readFromData:(NSData *)data
                                error:(NSError **)error;

/** Instance-returning variants that also expose chromatograms and
 *  parsed provenance separately, since v0.1 TTIOSpectralDataset has
 *  no chromatogram slot. Returns nil on failure. */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

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
