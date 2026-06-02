/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_REFERENCE_IMPORT_H
#define TTIO_REFERENCE_IMPORT_H

#import <Foundation/Foundation.h>
#import "Core/TTIOProgressSink.h"
#import "Providers/TTIOStorageProtocols.h"

@class TTIOSpectralDataset;

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
 * concatenate per-chromosome <code>sequence_bytes</code> verbatim
 * (case-preserving, no framing) into the digest. Unified in v1.1.0
 * with the REF_DIFF_V2 auto-embed writer's stamp; the previous
 * <code>name + 0x0A + seq + 0x0A</code> form is gone.</p>
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

/**
 * Read an embedded reference from
 * <code>/study/references/&lt;uri&gt;/</code>.
 *
 * <p>Layout (matches the writer in
 * <code>_TTIO_M93_EmbedReferences</code>):</p>
 * <ul>
 *   <li><code>refGroup</code> attribute <code>reference_uri</code> =
 *       the reference URI; falls back to
 *       <code>-[refGroup name]</code>.</li>
 *   <li><code>refGroup</code> attribute <code>md5</code> =
 *       lowercase-hex content MD5; preserved verbatim into the
 *       returned <code>TTIOReferenceImport</code> so byte-for-byte
 *       round-trip is maintained. Missing or malformed values fall
 *       back to recomputation in the constructor.</li>
 *   <li><code>refGroup/chromosomes/</code> = sub-group containing
 *       one child per chromosome.</li>
 *   <li><code>refGroup/chromosomes/&lt;name&gt;/data</code> = UINT8
 *       dataset of sequence bytes (case-preserving).</li>
 * </ul>
 *
 * <p>Chromosomes are returned in the order
 * <code>-[refGroup childNames]</code> reports them — the writer
 * sorts alphabetically before persisting, so for any file written
 * by this library the order is alphabetic.</p>
 *
 * @param refGroup the <code>/study/references/&lt;uri&gt;/</code>
 *                 group.
 * @return A fully-populated <code>TTIOReferenceImport</code>, or
 *         <code>nil</code> on storage failure.
 *
 * @since 1.1.0
 */
+ (nullable instancetype)readFromGroup:(id<TTIOStorageGroup>)refGroup;

/**
 * Embed this reference at
 * <code>/study/references/&lt;uri&gt;/</code> inside
 * <code>dataset</code>'s open storage backing.
 *
 * <p>Layout (cross-language byte-equal — matches Python's
 * <code>ReferenceImport.write_to_dataset</code> and the canonical
 * embed-helper writer used by <code>embedReference=YES</code>
 * runs):</p>
 * <ul>
 *   <li><code>/study/references/&lt;uri&gt;/</code> group with
 *       <code>@md5</code> (32-char lowercase hex) and
 *       <code>@reference_uri</code> attributes.</li>
 *   <li><code>chromosomes/&lt;name&gt;/</code> sub-group per
 *       chromosome, in alphabetic order, with an
 *       <code>@length</code> (int64) attribute.</li>
 *   <li><code>chromosomes/&lt;name&gt;/data</code> UINT8
 *       ZLIB-compressed dataset of sequence bytes.</li>
 * </ul>
 *
 * <p>If a reference with the same <code>uri</code> is already
 * embedded and <code>overwrite</code> is <code>NO</code>, returns
 * <code>NO</code> with a populated error in
 * <code>TTIOSpectralDatasetErrorDomain</code> code 2201 (mirrors
 * Python's <code>FileExistsError</code> and Java's
 * <code>IllegalStateException</code>). When <code>overwrite</code>
 * is <code>YES</code>, the existing group is deleted first.</p>
 *
 * @param dataset   Open dataset; must expose a writable
 *                  <code>TTIOStorageProvider</code> via
 *                  <code>-[TTIOSpectralDataset provider]</code>.
 * @param overwrite If <code>YES</code>, replace any existing
 *                  reference under the same URI.
 * @param error     Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure
 *         (with <code>error</code> populated).
 *
 * @since 1.1.0
 */
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
                 error:(NSError **)error;

/**
 * Overload of <code>-writeToDataset:overwrite:error:</code> that fires
 * <code>progress(i+1, totalChromosomes)</code> after each chromosome is
 * written (and <code>progress(0, total)</code> once before the loop),
 * mirroring Java's <code>writeToDataset(..., ProgressSink)</code> and
 * Python's <code>write_to_dataset(..., progress=...)</code>.
 *
 * @param progress Progress block; pass <code>nil</code> for none.
 * @since 1.6.4
 */
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
              progress:(nullable TTIOProgressBlock)progress
                 error:(NSError **)error;

/**
 * Convenience wrapper for
 * <code>-writeToDataset:overwrite:error:</code> that defaults
 * <code>overwrite</code> to <code>NO</code>, mirroring Python's
 * keyword-only default.
 *
 * @since 1.1.0
 */
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
                 error:(NSError **)error;

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
