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
 * BAM exporter — v0.12 M88.
 *
 * Writes a :class:`TTIOWrittenGenomicRun` to a BAM file by formatting
 * the in-memory parallel-array representation as SAM text and piping
 * that text via stdin to the user-installed ``samtools`` binary
 * (``samtools view -bS -``, optionally piped through ``samtools sort
 * -O bam``). Subprocess-only — no htslib linkage; SAM line layout is
 * from the public SAMv1 spec.
 *
 * Quality byte encoding
 * ---------------------
 * M87's :class:`TTIOBamReader` stores SAM's QUAL field bytes verbatim
 * into ``WrittenGenomicRun.qualitiesData`` — i.e. the buffer holds
 * **ASCII Phred+33** characters (so a Phred-40 score is stored as the
 * byte value 73, the ASCII code for ``'I'``). This writer mirrors that
 * convention: each ``qualities[i]`` byte is written directly as the
 * SAM QUAL character with no arithmetic adjustment. The pair is
 * therefore lossless byte-for-byte across the M87 read → M88 write
 * round trip.
 *
 * API status: Provisional (v0.12 M88).
 *
 * Cross-language equivalents:
 *   Python: ttio.exporters.bam.BamWriter
 *   Java:   global.thalion.ttio.exporters.BamWriter
 */
@interface TTIOBamWriter : NSObject

/** Output BAM file path. */
@property (nonatomic, readonly, copy) NSString *path;

/** Construct a writer for the BAM file at @a path. Does NOT require
 *  samtools at construction time per Binding Decision §135. */
- (instancetype)initWithPath:(NSString *)path;

/** Serialise @a run to the configured output path.
 *
 *  @param run         The genomic-run container to write.
 *  @param provenance  Optional provenance records to inject as ``@PG``
 *                     header lines. May be nil.
 *  @param sort        When YES (the default per Binding Decision §137),
 *                     pipes the SAM text through ``samtools sort -O bam``
 *                     so the output BAM is coordinate-sorted. When NO,
 *                     output is written in the input run's read order
 *                     and the ``@HD SO:`` tag is set to ``unsorted``.
 *  @param error       Out-param for failures.
 *  @returns           YES on success, NO on failure.
 */
- (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
   provenanceRecords:(nullable NSArray<TTIOProvenanceRecord *> *)provenance
                sort:(BOOL)sort
               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_BAM_WRITER_H */
