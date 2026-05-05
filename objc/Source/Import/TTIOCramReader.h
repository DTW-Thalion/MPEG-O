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
 * <heading>TTIOCramReader</heading>
 *
 * <p><em>Inherits From:</em> TTIOBamReader : NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOCramReader.h</p>
 *
 * <p>CRAM importer. Subclass of <code>TTIOBamReader</code> that adds
 * a required reference-FASTA argument so the underlying
 * <code>samtools view</code> invocation can decode the
 * reference-compressed sequence bytes. Per the cross-language binding
 * decision, the reference path is a positional constructor argument;
 * there is no environment-variable fallback and no RefGet HTTP
 * support.</p>
 *
 * <p>Internally re-implements
 * <code>-toGenomicRunWithName:region:sampleName:error:</code> with
 * the same SAM-text parsing path as the parent class but with a
 * <code>--reference &lt;fasta&gt;</code> argument injected into the
 * <code>samtools view</code> command line.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.cram.CramReader</code><br/>
 * Java: <code>global.thalion.ttio.importers.CramReader</code></p>
 */
@interface TTIOCramReader : TTIOBamReader

/** Path to the reference FASTA the CRAM was aligned against. */
@property (nonatomic, readonly, copy) NSString *referenceFasta;

/**
 * Designated initialiser. Both arguments are required.
 *
 * @param path           Path to the CRAM file.
 * @param referenceFasta Path to the reference FASTA against which
 *                       the CRAM was aligned.
 * @return An initialised CRAM reader.
 */
- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta;

/** Disabled &mdash; the parent's single-argument initialiser is not
 *  valid for CRAM (CRAM cannot be decoded without a reference). */
- (instancetype)initWithPath:(NSString *)path NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_CRAM_READER_H */
