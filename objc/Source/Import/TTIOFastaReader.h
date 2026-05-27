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

@end

NS_ASSUME_NONNULL_END

#endif
