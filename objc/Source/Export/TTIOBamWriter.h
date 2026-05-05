/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_BAM_WRITER_H
#define TTIO_BAM_WRITER_H

#import <Foundation/Foundation.h>

@class TTIOWrittenGenomicRun;
@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOBamWriter</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOBamWriter.h</p>
 *
 * <p>BAM exporter. Writes a <code>TTIOWrittenGenomicRun</code> to a
 * BAM file by formatting the in-memory parallel-array representation
 * as SAM text and piping that text via stdin to the user-installed
 * <code>samtools</code> binary (<code>samtools view -bS -</code>,
 * optionally piped through <code>samtools sort -O bam</code>).
 * Subprocess-only &mdash; no htslib linkage; SAM line layout follows
 * the public SAMv1 specification.</p>
 *
 * <p><strong>Quality byte encoding:</strong>
 * <code>TTIOBamReader</code> stores SAM's QUAL field bytes verbatim
 * into <code>WrittenGenomicRun.qualitiesData</code> &mdash; the
 * buffer holds <em>ASCII Phred+33</em> characters (so a Phred-40
 * score is stored as the byte value 73, the ASCII code for
 * <code>'I'</code>). This writer mirrors that convention: each
 * <code>qualities[i]</code> byte is written directly as the SAM
 * QUAL character with no arithmetic adjustment. The pair is
 * therefore lossless byte-for-byte across read &rarr; write
 * round-trip.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.bam.BamWriter</code><br/>
 * Java: <code>global.thalion.ttio.exporters.BamWriter</code></p>
 */
@interface TTIOBamWriter : NSObject

/** Output BAM file path. */
@property (nonatomic, readonly, copy) NSString *path;

/** Constructs a writer for the BAM file at @a path. Does NOT
 *  require <code>samtools</code> at construction time. */
- (instancetype)initWithPath:(NSString *)path;

/** Serialises @a run to the configured output path.
 *
 *  @param run         The genomic-run container to write.
 *  @param provenance  Optional provenance records to inject as
 *                     <code>@PG</code> header lines. May be
 *                     <code>nil</code>.
 *  @param sort        When <code>YES</code> (the default), pipes the
 *                     SAM text through
 *                     <code>samtools sort -O bam</code> so the
 *                     output BAM is coordinate-sorted. When
 *                     <code>NO</code>, output is written in the
 *                     input run's read order and the
 *                     <code>@HD SO:</code> tag is set to
 *                     <code>unsorted</code>.
 *  @param error       Out-parameter populated on failure.
 *  @return            <code>YES</code> on success, <code>NO</code>
 *                     on failure.
 */
- (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
   provenanceRecords:(nullable NSArray<TTIOProvenanceRecord *> *)provenance
                sort:(BOOL)sort
               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_BAM_WRITER_H */
