/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_FASTA_READER_H
#define TTIO_FASTA_READER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "Core/TTIOProgressSink.h"

@class TTIOReferenceImport;
@class TTIOWrittenGenomicRun;
@class TTIOGenomicStreamSource;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TTIOFastaReaderErrorDomain;

/** Emit-every-N cadence for {@link TTIOProgressBlock} callbacks
 *  during FASTA parsing. Mirrors Java's
 *  {@code FastaReader.PROGRESS_INTERVAL_READS}. */
FOUNDATION_EXPORT const NSUInteger TTIOFastaReaderProgressIntervalReads;

typedef NS_ENUM(NSInteger, TTIOFastaReaderErrorCode) {
    TTIOFastaReaderErrorMissingFile      = 1,
    TTIOFastaReaderErrorParseFailed      = 2,
    TTIOFastaReaderErrorEmptyInput       = 3,
};

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOFastaReader.h</p>
 *
 * <p>FASTA importer. Parses a FASTA file into either a
 * <code>TTIOReferenceImport</code> (reference-genome embedding) or
 * an unaligned <code>TTIOWrittenGenomicRun</code> (panels, target
 * lists, quality-stripped reads).</p>
 *
 * <p>gzip-compressed input is auto-detected via the
 * <code>1f 8b</code> magic bytes regardless of file extension.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.fasta.FastaReader</code><br/>
 * Java: <code>global.thalion.ttio.importers.FastaReader</code></p>
 */
@interface TTIOFastaReader : NSObject

/**
 * Parse the file as a reference genome.
 *
 * @param path  FASTA file path.
 * @param uri   Reference URI, or <code>nil</code> to derive from
 *              the filename stem.
 * @param error Out-parameter populated on failure.
 * @return <code>TTIOReferenceImport</code> on success, or
 *         <code>nil</code> on failure.
 */
+ (nullable TTIOReferenceImport *)readReferenceFromPath:(NSString *)path
                                                     uri:(nullable NSString *)uri
                                                   error:(NSError **)error;

/**
 * Parse the file as a set of unaligned reads.
 *
 * @param path             FASTA file path.
 * @param sampleName       Sample tag for the run.
 * @param platform         Platform tag.
 * @param referenceUri     Reference URI to record on the run.
 * @param acquisitionMode  Run-level acquisition mode.
 * @param error            Out-parameter populated on failure.
 * @return <code>TTIOWrittenGenomicRun</code> on success, or
 *         <code>nil</code> on failure.
 */
+ (nullable TTIOWrittenGenomicRun *)readUnalignedFromPath:(NSString *)path
                                                sampleName:(NSString *)sampleName
                                                  platform:(NSString *)platform
                                              referenceUri:(NSString *)referenceUri
                                           acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                                                     error:(NSError **)error;

/**
 * Progress-aware overload of
 * {@link readUnalignedFromPath:sampleName:platform:referenceUri:acquisitionMode:error:}.
 *
 * Fires {@code progress(readsDone, -1)} every
 * {@link TTIOFastaReaderProgressIntervalReads} records during the
 * parse phase, and a final {@code progress(total, total)} once the
 * record count is known. Pass {@code nil} for {@code progress} to
 * skip all callbacks; existing callers are unaffected.
 *
 * @param progress Optional progress block. {@code nil} = no callbacks.
 */
+ (nullable TTIOWrittenGenomicRun *)readUnalignedFromPath:(NSString *)path
                                                sampleName:(NSString *)sampleName
                                                  platform:(NSString *)platform
                                              referenceUri:(NSString *)referenceUri
                                           acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                                                  progress:(nullable TTIOProgressBlock)progress
                                                     error:(NSError **)error;

/** Reads per streamed batch by default (100 000). */
FOUNDATION_EXPORT const NSUInteger TTIOFastaReaderDefaultBatchReads;

/** Sequence + sentinel-quality bytes per streamed batch by default
 *  (64 MiB). Bytes are the primary batch limit: a read count is blind
 *  to record length. */
FOUNDATION_EXPORT const unsigned long long TTIOFastaReaderDefaultBatchBytes;

/**
 * Walk the records in batches of <code>batchReads</code> reads, each
 * batch an unaligned run of its own carrying the SAM-unmapped
 * sentinels of <code>+readUnalignedFromPath:…</code>, so a file of
 * any size is imported with bounded memory. <code>block</code>
 * returns NO to stop (its <code>error</code> is reported).
 */
+ (BOOL)iterBatchesFromPath:(NSString *)path
                 sampleName:(NSString *)sampleName
                   platform:(NSString *)platform
               referenceUri:(NSString *)referenceUri
            acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                 batchReads:(NSUInteger)batchReads
                   progress:(nullable TTIOProgressBlock)progress
                      error:(NSError **)error
                 usingBlock:(BOOL (^)(TTIOWrittenGenomicRun *batch, NSError **error))block;

/** As above with an explicit byte limit; a batch cuts at whichever of
 *  <code>batchReads</code> / <code>batchBytes</code> is hit first
 *  (0 = the default for each). */
+ (BOOL)iterBatchesFromPath:(NSString *)path
                 sampleName:(NSString *)sampleName
                   platform:(NSString *)platform
               referenceUri:(NSString *)referenceUri
            acquisitionMode:(TTIOAcquisitionMode)acquisitionMode
                 batchReads:(NSUInteger)batchReads
                 batchBytes:(unsigned long long)batchBytes
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

/** As above with the byte limit of
 *  <code>+iterBatchesFromPath:…batchBytes:…</code>. */
+ (TTIOGenomicStreamSource *)streamFromPath:(NSString *)path
                                       name:(NSString *)name
                                 sampleName:(NSString *)sampleName
                                 batchReads:(NSUInteger)batchReads
                                 batchBytes:(unsigned long long)batchBytes
                                   progress:(nullable TTIOProgressBlock)progress;

@end

NS_ASSUME_NONNULL_END

#endif
