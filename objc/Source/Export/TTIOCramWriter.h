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
 * <heading>TTIOCramWriter</heading>
 *
 * <p><em>Inherits From:</em> TTIOBamWriter : NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOCramWriter.h</p>
 *
 * <p>CRAM exporter. Subclass of <code>TTIOBamWriter</code> that
 * overrides the <code>samtools</code> subprocess invocation to emit
 * CRAM (reference-compressed) output instead of BAM. Per the
 * cross-language binding decision, the reference FASTA is a
 * positional constructor argument; <code>samtools</code> needs it
 * for both the <code>view -CS</code> and the
 * <code>sort -O cram</code> stages.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.cram.CramWriter</code><br/>
 * Java: <code>global.thalion.ttio.exporters.CramWriter</code></p>
 */
@interface TTIOCramWriter : TTIOBamWriter

/** Path to the reference FASTA used to compress the CRAM output. */
@property (nonatomic, readonly, copy) NSString *referenceFasta;

/**
 * Designated initialiser. Both arguments are required.
 *
 * @param path           Output CRAM file path.
 * @param referenceFasta Path to the reference FASTA used to compress
 *                       the output.
 * @return An initialised CRAM writer.
 */
- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta;

/** Disabled &mdash; CRAM writes always need a reference. */
- (instancetype)initWithPath:(NSString *)path NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_CRAM_WRITER_H */
