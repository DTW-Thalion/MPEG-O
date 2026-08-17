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
#import "Core/TTIOProgressSink.h"

@class TTIOWrittenGenomicRun;
@class TTIOGenomicStreamSource;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TTIOFastqReaderErrorDomain;

/** Emit-every-N cadence for {@link TTIOProgressBlock} callbacks
 *  during FASTQ parsing. Mirrors Java's
 *  {@code FastqReader.PROGRESS_INTERVAL_READS}. */
FOUNDATION_EXPORT const NSUInteger TTIOFastqReaderProgressIntervalReads;

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

/**
 * Progress-aware overload of
 * {@link readFromPath:forcedPhred:sampleName:platform:referenceUri:acquisitionMode:outDetected:error:}.
 *
 * Fires {@code progress(readsDone, -1)} every
 * {@link TTIOFastqReaderProgressIntervalReads} records during the
 * parse phase, and a final {@code progress(total, total)} once the
 * record count is known. Pass {@code nil} for {@code progress} to
 * skip all callbacks; existing callers are unaffected.
 *
 * @param progress Optional progress block. {@code nil} = no callbacks.
 */
+ (nullable TTIOWrittenGenomicRun *)readFromPath:(NSString *)path
                                     forcedPhred:(uint8_t)forcedPhred
                                      sampleName:(NSString *)sampleName
                                        platform:(NSString *)platform
                                    referenceUri:(NSString *)referenceUri
                                 acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                                     outDetected:(nullable uint8_t *)outDetected
                                        progress:(nullable TTIOProgressBlock)progress
                                           error:(NSError **)error;

/** Reads per streamed batch by default (100 000). */
FOUNDATION_EXPORT const NSUInteger TTIOFastqReaderDefaultBatchReads;

/**
 * Walk the records in batches of <code>batchReads</code> reads, each
 * batch an unaligned run of its own, so a file of any size is imported
 * with bounded memory. The Phred offset is detected on the first
 * batch's qualities (or forced) and applied to every batch;
 * <code>outDetected</code> receives it. <code>block</code> returns NO
 * to stop (its <code>error</code> is reported).
 */
+ (BOOL)iterBatchesFromPath:(NSString *)path
                forcedPhred:(uint8_t)forcedPhred
                 sampleName:(NSString *)sampleName
                   platform:(NSString *)platform
               referenceUri:(NSString *)referenceUri
            acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                 batchReads:(NSUInteger)batchReads
                outDetected:(nullable uint8_t *)outDetected
                   progress:(nullable TTIOProgressBlock)progress
                      error:(NSError **)error
                 usingBlock:(BOOL (^)(TTIOWrittenGenomicRun *batch, NSError **error))block;

/** The batches of <code>+iterBatchesFromPath:…</code> as a
 *  TTIOGenomicStreamSource named <code>name</code>. */
+ (TTIOGenomicStreamSource *)streamFromPath:(NSString *)path
                                       name:(NSString *)name
                                 sampleName:(NSString *)sampleName
                                 batchReads:(NSUInteger)batchReads
                                   progress:(nullable TTIOProgressBlock)progress;

@end

NS_ASSUME_NONNULL_END

#endif
