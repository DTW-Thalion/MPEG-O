/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_BAM_READER_H
#define TTIO_BAM_READER_H

#import <Foundation/Foundation.h>

@class TTIOWrittenGenomicRun;
@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

/**
 * SAM/BAM importer — v0.12 M87.
 *
 * Wraps the user-installed ``samtools`` binary as a subprocess (via
 * ``NSTask``) to read SAM and BAM (Sequence Alignment/Map) files into
 * :class:`TTIOWrittenGenomicRun` instances. No htslib source is linked
 * or consulted; SAM/BAM format parsing is from the public SAMv1
 * specification (https://samtools.github.io/hts-specs).
 *
 * The subprocess approach mirrors the M53 Bruker timsTOF importer.
 * ``samtools`` is a runtime dependency only — instantiating
 * ``TTIOBamReader`` succeeds on systems without samtools; only
 * :meth:`-toGenomicRunWithName:region:sampleName:error:` requires the
 * binary on PATH (Binding Decision §135). The first such call probes
 * ``samtools --version`` via NSTask; missing or broken installations
 * fail with an NSError whose message includes apt / brew / conda
 * install hints.
 *
 * samtools auto-detects SAM vs BAM format from magic bytes; a single
 * parser handles both formats. The companion :class:`TTIOSamReader`
 * exists as a discoverable convenience alias.
 *
 * API status: Provisional (v0.12 M87).
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.bam.BamReader
 *   Java:   global.thalion.ttio.importers.BamReader
 */
@interface TTIOBamReader : NSObject

/** Path to the SAM or BAM file this reader was constructed for. */
@property (nonatomic, readonly, copy) NSString *path;

/** Provenance records derived from the SAM ``@PG`` chain on the most
 *  recent successful call to
 *  :meth:`-toGenomicRunWithName:region:sampleName:error:`. Each
 *  ``@PG`` line becomes one :class:`TTIOProvenanceRecord` whose
 *  ``software`` is the ``PN:`` field and whose ``parameters`` carry
 *  the ``CL:``, ``ID:``, ``VN:``, ``PP:`` fields verbatim.
 *  ``timestampUnix`` is taken from the input file's mtime since SAM
 *  has no per-record timestamps (HANDOFF §2.4).
 *
 *  Empty (not nil) before the first successful call, and replaced
 *  on each call. Companion to the cross-language ``provenance_count``
 *  field in the canonical bam_dump JSON. */
@property (nonatomic, readonly, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** Construct a reader for the SAM/BAM file at @a path. Does NOT require
 *  samtools at construction time per Binding Decision §135. */
- (instancetype)initWithPath:(NSString *)path;

/** Read the SAM/BAM and return a write-side genomic run.
 *
 *  @param name        Genomic-run name (default ``@"genomic_0001"`` if
 *                     nil); becomes the subgroup name under
 *                     ``/study/genomic_runs/<name>/``.
 *  @param region      Optional region filter passed verbatim to
 *                     ``samtools view`` (e.g. ``@"chr1:1000-2000"`` or
 *                     ``@"*"`` for unmapped reads). Pass nil for
 *                     full-file iteration.
 *  @param sampleName  Optional override for ``WrittenGenomicRun.sampleName``.
 *                     If nil, falls back to the first ``@RG SM:`` tag
 *                     in the SAM header (or ``@""`` if no @RG present).
 *  @param error       Out-param for failures: samtools missing,
 *                     non-zero samtools exit, file not found,
 *                     malformed SAM line.
 *  @returns           A populated :class:`TTIOWrittenGenomicRun`, or nil
 *                     on any error.
 */
- (nullable TTIOWrittenGenomicRun *)toGenomicRunWithName:(nullable NSString *)name
                                                   region:(nullable NSString *)region
                                               sampleName:(nullable NSString *)sampleName
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_BAM_READER_H */
