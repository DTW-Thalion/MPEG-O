/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_FASTA_WRITER_H
#define TTIO_FASTA_WRITER_H

#import <Foundation/Foundation.h>

@class TTIOReferenceImport;
@class TTIOWrittenGenomicRun;
@class TTIOGenomicRun;

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger TTIOFastaWriterDefaultLineWidth;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOFastaWriter.h</p>
 *
 * <p>FASTA exporter for reference imports and unaligned genomic
 * runs. Configurable line-wrap (default 60), samtools-compatible
 * <code>.fai</code> index emitted alongside, gzip on
 * <code>.gz</code> destination.</p>
 *
 * <p>Cross-language byte-equality (uncompressed): header is
 * <code>"&gt;name\n"</code>, sequence wrapped at the configured
 * width, line endings LF only.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.fasta.FastaWriter</code><br/>
 * Java: <code>global.thalion.ttio.exporters.FastaWriter</code></p>
 */
@interface TTIOFastaWriter : NSObject

/**
 * Write a reference import to <code>path</code>.
 *
 * @param reference  Source reference.
 * @param path       Destination path.
 * @param lineWidth  Sequence wrap width (>= 1).
 * @param gzipOutput <code>0</code> = derive from <code>.gz</code>
 *                   suffix; <code>1</code> = force gzip on;
 *                   <code>-1</code> = force off.
 * @param writeFai   When <code>YES</code>, emit a samtools-style
 *                   <code>.fai</code> index alongside (skipped
 *                   silently for gzip output).
 * @param error      Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
+ (BOOL)writeReference:(TTIOReferenceImport *)reference
                toPath:(NSString *)path
             lineWidth:(NSUInteger)lineWidth
            gzipOutput:(int)gzipOutput
              writeFai:(BOOL)writeFai
                 error:(NSError **)error;

/**
 * Write a write-side genomic run as FASTA. Each read becomes one
 * record (quality bytes are discarded).
 */
+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
       lineWidth:(NSUInteger)lineWidth
      gzipOutput:(int)gzipOutput
        writeFai:(BOOL)writeFai
           error:(NSError **)error;

/**
 * Write a read-side <code>TTIOGenomicRun</code> as FASTA. Used by
 * the FASTA-from-<code>.tio</code> export path.
 */
+ (BOOL)writeReadSideRun:(TTIOGenomicRun *)run
                  toPath:(NSString *)path
               lineWidth:(NSUInteger)lineWidth
              gzipOutput:(int)gzipOutput
                writeFai:(BOOL)writeFai
                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
