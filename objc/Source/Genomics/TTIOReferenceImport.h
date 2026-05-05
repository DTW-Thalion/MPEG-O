/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_REFERENCE_IMPORT_H
#define TTIO_REFERENCE_IMPORT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Genomics/TTIOReferenceImport.h</p>
 *
 * <p>Reference-FASTA value class staged for embedding into a
 * <code>.tio</code> container. Carries chromosome names, per-
 * chromosome sequence bytes, and a content MD5 suitable for the
 * <code>@md5</code> attribute on
 * <code>/study/references/&lt;uri&gt;/</code> groups.</p>
 *
 * <p>Cross-language byte-equal MD5: sort by chromosome name, then
 * digest <code>utf8(name) + 0x0A + sequence_bytes + 0x0A</code> for
 * each entry. The trailing <code>0x0A</code> separators never appear
 * inside FASTA sequence bytes, so the digest is unambiguous.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.genomic.reference_import.ReferenceImport</code><br/>
 * Java:
 * <code>global.thalion.ttio.genomics.ReferenceImport</code></p>
 */
@interface TTIOReferenceImport : NSObject

/** Reference URI (e.g. <code>@"GRCh38.p14"</code>). */
@property (nonatomic, readonly, copy) NSString *uri;

/** Chromosome names in FASTA file order. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *chromosomes;

/** Per-chromosome sequence bytes (case-preserving). */
@property (nonatomic, readonly, copy) NSArray<NSData *> *sequences;

/** 16-byte content MD5. */
@property (nonatomic, readonly, copy) NSData *md5;

/**
 * Designated initialiser. Computes MD5 from the chromosome set if
 * <code>md5</code> is <code>nil</code>.
 */
- (instancetype)initWithUri:(NSString *)uri
                chromosomes:(NSArray<NSString *> *)chromosomes
                  sequences:(NSArray<NSData *> *)sequences
                        md5:(nullable NSData *)md5;

/** Convenience initialiser that always computes the MD5. */
- (instancetype)initWithUri:(NSString *)uri
                chromosomes:(NSArray<NSString *> *)chromosomes
                  sequences:(NSArray<NSData *> *)sequences;

/**
 * Compute the canonical content-MD5 over a chromosome set.
 *
 * @param chromosomes Chromosome names.
 * @param sequences   Per-chromosome bytes.
 * @return 16-byte MD5 digest.
 */
+ (NSData *)computeMd5WithChromosomes:(NSArray<NSString *> *)chromosomes
                            sequences:(NSArray<NSData *> *)sequences;

/** Total bases across all chromosomes. */
- (NSUInteger)totalBases;

/**
 * Look up a chromosome by name.
 *
 * @return Sequence bytes, or <code>nil</code> if not present.
 */
- (nullable NSData *)chromosomeNamed:(NSString *)name;

/** Lowercase-hex form of the MD5. */
- (NSString *)md5Hex;

@end

NS_ASSUME_NONNULL_END

#endif
