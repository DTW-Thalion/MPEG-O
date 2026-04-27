/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_CRAM_READER_H
#define TTIO_CRAM_READER_H

#import "TTIOBamReader.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * CRAM importer — v0.12 M88.
 *
 * Subclass of :class:`TTIOBamReader` that adds a required reference-FASTA
 * argument so the underlying ``samtools view`` invocation can decode the
 * reference-compressed sequence bytes. Per Binding Decision §139 the
 * reference path is a positional constructor argument; no env-var
 * fallback, no RefGet HTTP support in v0.
 *
 * Internally re-implements :meth:`-toGenomicRunWithName:region:sampleName:error:`
 * with the same SAM-text parsing path as the parent class but with an
 * ``--reference <fasta>`` argument injected into the ``samtools view``
 * command line.
 *
 * API status: Provisional (v0.12 M88).
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.cram.CramReader
 *   Java:   global.thalion.ttio.importers.CramReader
 */
@interface TTIOCramReader : TTIOBamReader

/** Path to the reference FASTA the CRAM was aligned against. */
@property (nonatomic, readonly, copy) NSString *referenceFasta;

/** Construct a CRAM reader. Both arguments are required. */
- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta;

/** Disabled — the parent's single-arg initialiser is not valid for CRAM
 *  (CRAM cannot be decoded without a reference; Binding Decision §139). */
- (instancetype)initWithPath:(NSString *)path NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_CRAM_READER_H */
