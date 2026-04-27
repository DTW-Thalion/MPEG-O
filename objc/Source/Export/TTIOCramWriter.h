/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_CRAM_WRITER_H
#define TTIO_CRAM_WRITER_H

#import "TTIOBamWriter.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * CRAM exporter — v0.12 M88.
 *
 * Subclass of :class:`TTIOBamWriter` that overrides the samtools
 * subprocess invocation to emit CRAM (reference-compressed) output
 * instead of BAM. Per Binding Decision §139 the reference FASTA is a
 * positional constructor argument; samtools needs it for both the
 * ``view -CS`` and the ``sort -O cram`` stages.
 *
 * API status: Provisional (v0.12 M88).
 *
 * Cross-language equivalents:
 *   Python: ttio.exporters.cram.CramWriter
 *   Java:   global.thalion.ttio.exporters.CramWriter
 */
@interface TTIOCramWriter : TTIOBamWriter

/** Path to the reference FASTA used to compress the CRAM output. */
@property (nonatomic, readonly, copy) NSString *referenceFasta;

/** Construct a CRAM writer. Both arguments are required. */
- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta;

/** Disabled — CRAM writes always need a reference (Binding Decision §139). */
- (instancetype)initWithPath:(NSString *)path NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_CRAM_WRITER_H */
