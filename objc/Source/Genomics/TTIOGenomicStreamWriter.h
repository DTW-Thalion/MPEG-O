/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_GENOMIC_STREAM_WRITER_H
#define TTIO_GENOMIC_STREAM_WRITER_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOWrittenGenomicRun;
@class TTIOAlignedRead;
@class TTIOProvenanceRecord;
@class TTIOCompoundField;

NS_ASSUME_NONNULL_BEGIN

/** Run-level options of a streamed genomic run. Python:
 *  <code>GenomicStreamWriter</code> keyword arguments; Java:
 *  <code>GenomicStreamWriter.Options</code>. */
@interface TTIOGenomicStreamWriterOptions : NSObject <NSCopying>
@property (nonatomic) TTIOAcquisitionMode acquisitionMode;
@property (nonatomic, copy, nullable) NSString *referenceUri;
@property (nonatomic, copy, nullable) NSString *platform;
@property (nonatomic, copy, nullable) NSString *sampleName;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSData *> *referenceChromSeqs;
@property (nonatomic) BOOL embedReference;
/** Reads per block; default 1 000 000. */
@property (nonatomic) NSUInteger blockReads;
/** Sequence bytes per block; default 256 MiB. */
@property (nonatomic) unsigned long long blockBytes;
@property (nonatomic) BOOL optDisableQualitiesV5;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *signalCodecOverrides;
@property (nonatomic) TTIOCompression signalCompression;
@property (nonatomic) BOOL optLegacyWholeChannel;
@property (nonatomic, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** Defaults: zlib, no overrides, default block policy. */
+ (instancetype)defaultOptions;
/** The run-level metadata of <code>run</code>, default block policy. */
+ (instancetype)optionsFromRun:(TTIOWrittenGenomicRun *)run;
@end

/** Writes one genomic run as blocks_v1 (format-spec 10.12) with bounded
 *  memory. Reads are buffered until a block is full (blockReads reads or
 *  blockBytes sequence bytes, whichever first; a block never spans two
 *  chromosomes), encoded through TTIOGenomicBlocks and appended to
 *  extendable per-channel datasets; blocks/index records where each
 *  block's blob lives. Python: <code>ttio.genomic.GenomicStreamWriter</code>;
 *  Java: <code>GenomicStreamWriter</code>. */
@interface TTIOGenomicStreamWriter : NSObject

/** The layout attribute value, <code>blocks_v1</code>. */
+ (NSString *)layout;
/** Chunk of the unfiltered channel datasets (256 KiB). */
+ (NSUInteger)channelChunk;
/** Block index schema, in the column order of format-spec 10.12.2. */
+ (NSArray<TTIOCompoundField *> *)indexFields;

/** Append reads to run <code>runName</code> of the /study group
 *  <code>study</code>; the writer creates genomic_runs when absent and
 *  maintains its @_run_names. */
- (instancetype)initWithStudyGroup:(id<TTIOStorageGroup>)study
                           runName:(NSString *)runName
                           options:(nullable TTIOGenomicStreamWriterOptions *)options;

/** Append one read. */
- (BOOL)appendRead:(TTIOAlignedRead *)read error:(NSError **)error;
/** Append the reads of <code>batch</code>; its run-level metadata is
 *  ignored, the writer's options apply. */
- (BOOL)appendBatch:(TTIOWrittenGenomicRun *)batch error:(NSError **)error;
/** Encode and write the pending reads as one block. */
- (BOOL)flush:(NSError **)error;
/** Flush, write the name tables and provenance. Idempotent. */
- (BOOL)close:(NSError **)error;

@property (nonatomic, readonly) unsigned long long readCount;
@property (nonatomic, readonly) NSUInteger blockCount;
@property (nonatomic, readonly, copy) TTIOGenomicStreamWriterOptions *options;

@end

NS_ASSUME_NONNULL_END

#endif
