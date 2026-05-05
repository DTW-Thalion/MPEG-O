/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_FASTQ_READER_H
#define TTIO_FASTQ_READER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOWrittenGenomicRun;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TTIOFastqReaderErrorDomain;

typedef NS_ENUM(NSInteger, TTIOFastqReaderErrorCode) {
    TTIOFastqReaderErrorMissingFile      = 1,
    TTIOFastqReaderErrorParseFailed      = 2,
    TTIOFastqReaderErrorEmptyInput       = 3,
};

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOFastqReader.h</p>
 *
 * <p>FASTQ importer. Parses 4-line records into unaligned
 * <code>TTIOWrittenGenomicRun</code> instances. Internal storage
 * is always Phred+33 ASCII.</p>
 *
 * <p>Phred encoding is auto-detected by inspecting the qualities
 * byte range. Override with the <code>forcedPhred</code>
 * argument.</p>
 *
 * <p>gzip-compressed input is auto-detected.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.fastq.FastqReader</code><br/>
 * Java: <code>global.thalion.ttio.importers.FastqReader</code></p>
 */
@interface TTIOFastqReader : NSObject

/**
 * Phred-offset detection heuristic over a quality-bytes sample.
 *
 * @param qualities Concatenated quality bytes.
 * @return <code>33</code> or <code>64</code>.
 */
+ (uint8_t)detectPhredOffsetFromBytes:(NSData *)qualities;

/**
 * Parse the FASTQ file.
 *
 * @param path             FASTQ file path.
 * @param forcedPhred      <code>0</code> = auto-detect, otherwise
 *                         must be <code>33</code> or <code>64</code>.
 * @param sampleName       Sample tag for the run.
 * @param platform         Platform tag.
 * @param referenceUri     Reference URI to record.
 * @param acquisitionMode  Run-level acquisition mode.
 * @param outDetected      Optional out-parameter receiving the
 *                         offset actually applied.
 * @param error            Out-parameter populated on failure.
 * @return The unaligned run on success, or <code>nil</code> on
 *         failure.
 */
+ (nullable TTIOWrittenGenomicRun *)readFromPath:(NSString *)path
                                     forcedPhred:(uint8_t)forcedPhred
                                      sampleName:(NSString *)sampleName
                                        platform:(NSString *)platform
                                    referenceUri:(NSString *)referenceUri
                                 acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                                     outDetected:(nullable uint8_t *)outDetected
                                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
