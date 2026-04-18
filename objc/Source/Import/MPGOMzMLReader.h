/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_MZML_READER_H
#define MPGO_MZML_READER_H

#import <Foundation/Foundation.h>

@class MPGOSpectralDataset;
@class MPGOChromatogram;

/**
 * SAX-based mzML 1.1 parser. Consumes an mzML document and produces a
 * populated MPGOSpectralDataset containing one MPGOAcquisitionRun per
 * &lt;run&gt; element. Chromatograms appear as extra spectra carrying the
 * MPGOChromatogram class tag.
 *
 * What is parsed:
 *   - &lt;spectrum&gt; elements with cvParam-driven metadata (MS level,
 *     polarity, scan start time, scan window, precursor m/z &amp; charge)
 *   - &lt;binaryDataArray&gt; payloads decoded via MPGOBase64, typed via
 *     MPGOCVTermMapper, packaged as MPGOSignalArray
 *   - &lt;chromatogram&gt; elements with time + intensity arrays
 *   - &lt;dataProcessing&gt; as MPGOProvenanceRecord chain (best-effort)
 *
 * What is ignored (v0.2):
 *   - spectrumRef / sourceFileRef cross-references
 *   - softwareList (captured as provenance agent names only)
 *   - fileDescription except for the list of source files
 *
 * On malformed input the reader returns nil and populates `error` with a
 * descriptive NSError in the `MPGOMzMLReaderErrorDomain`. Not thread-safe.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.importers.mzml
 *   Java:   com.dtwthalion.mpgo.importers.MzMLReader
 */
@interface MPGOMzMLReader : NSObject

/** One-shot class methods. Return only the dataset. */
+ (MPGOSpectralDataset *)readFromFilePath:(NSString *)path
                                    error:(NSError **)error;
+ (MPGOSpectralDataset *)readFromURL:(NSURL *)url
                               error:(NSError **)error;
+ (MPGOSpectralDataset *)readFromData:(NSData *)data
                                error:(NSError **)error;

/** Instance-returning variants that also expose chromatograms and
 *  parsed provenance separately, since v0.1 MPGOSpectralDataset has
 *  no chromatogram slot. Returns nil on failure. */
+ (instancetype)parseFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)parseData:(NSData *)data error:(NSError **)error;

@property (readonly, strong) MPGOSpectralDataset                *dataset;
@property (readonly, copy)   NSArray<MPGOChromatogram *>        *chromatograms;

@end

extern NSString *const MPGOMzMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, MPGOMzMLReaderErrorCode) {
    MPGOMzMLReaderErrorParseFailed       = 1,
    MPGOMzMLReaderErrorMissingSpectrumList = 2,
    MPGOMzMLReaderErrorArrayLengthMismatch = 3,
    MPGOMzMLReaderErrorBase64Failed      = 4,
    MPGOMzMLReaderErrorUnsupportedEncoding = 5
};

#endif /* MPGO_MZML_READER_H */
