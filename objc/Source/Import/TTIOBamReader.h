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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOBamReader.h</p>
 *
 * <p>SAM/BAM importer. Wraps the user-installed
 * <code>samtools</code> binary as a subprocess (via
 * <code>NSTask</code>) to read SAM and BAM (Sequence Alignment/Map)
 * files into <code>TTIOWrittenGenomicRun</code> instances. No htslib
 * source is linked or consulted; SAM/BAM format parsing is from the
 * public SAMv1 specification
 * (<code>https://samtools.github.io/hts-specs</code>).</p>
 *
 * <p>The subprocess approach mirrors the Bruker timsTOF importer.
 * <code>samtools</code> is a runtime dependency only &#8212;
 * instantiating <code>TTIOBamReader</code> succeeds on systems
 * without <code>samtools</code>; only
 * <code>-toGenomicRunWithName:region:sampleName:error:</code> requires
 * the binary on <code>PATH</code>. The first such call probes
 * <code>samtools --version</code> via <code>NSTask</code>; missing or
 * broken installations fail with an <code>NSError</code> whose
 * message includes apt / brew / conda install hints.</p>
 *
 * <p><code>samtools</code> auto-detects SAM vs BAM format from magic
 * bytes; a single parser handles both formats. The companion
 * <code>TTIOSamReader</code> exists as a discoverable convenience
 * alias.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.bam.BamReader</code><br/>
 * Java: <code>global.thalion.ttio.importers.BamReader</code></p>
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
 *  <code>timestampUnix</code> is taken from the input file's mtime
 *  since SAM has no per-record timestamps.
 *
 *  Empty (not nil) before the first successful call, and replaced
 *  on each call. Companion to the cross-language ``provenance_count``
 *  field in the canonical bam_dump JSON. */
@property (nonatomic, readonly, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** Construct a reader for the SAM/BAM file at @a path. Does NOT require
 *  <code>samtools</code> at construction time. */
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
