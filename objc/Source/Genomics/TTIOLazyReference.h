/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_LAZY_REFERENCE_H
#define TTIO_LAZY_REFERENCE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** A chromosome-name to sequence-bytes dictionary over an indexed FASTA
 *  that loads a chromosome on <code>-objectForKey:</code> and keeps a
 *  small LRU of loaded chromosomes, so a run's
 *  <code>referenceChromSeqs</code> need not hold the genome in memory.
 *  Reads <code>&lt;fasta&gt;.fai</code>; when it is absent the FASTA is
 *  scanned once in-process and the index written next to it (kept in
 *  memory when the directory is not writable). Values are the raw
 *  sequence bytes with newlines removed, case preserved. Python:
 *  <code>ttio.genomic.LazyReference</code>; Java:
 *  <code>LazyReference</code>. */
@interface TTIOLazyReference : NSDictionary<NSString *, NSData *>

/** Two chromosomes cached. */
- (nullable instancetype)initWithFastaPath:(NSString *)path error:(NSError **)error;
/** <code>cacheChroms</code> chromosomes cached, least recently used out. */
- (nullable instancetype)initWithFastaPath:(NSString *)path
                               cacheChroms:(NSUInteger)cacheChroms
                                     error:(NSError **)error;

@property (nonatomic, readonly, copy) NSString *fastaPath;
/** Chromosome names in FASTA order. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *chromosomeNames;
/** Length of a chromosome without loading it; NSNotFound when unknown. */
- (NSUInteger)lengthOf:(NSString *)name;
/** 16-byte MD5 of the concatenated case-preserved sequences of every
 *  chromosome in alphabetic order of name: the reference-set digest
 *  every writer records (format spec section 10.10). Streams one
 *  chromosome at a time. */
- (NSData *)setMD5;

@end

NS_ASSUME_NONNULL_END

#endif
