/* SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOFastqParallelProducer
 *
 * The parallel FASTQ producer behind TTIOFastqReader's stream source.
 * Pipeline mode: the calling thread does the sequential work (reading
 * or inflating bytes and the cheap newline scan that slices whole
 * records), record parsing runs on the shared pool, and an ordered
 * assembler hands batches back in file order, so the emitted record
 * stream is identical to the serial producer's.
 */
#ifndef TTIO_FASTQ_PARALLEL_PRODUCER_H
#define TTIO_FASTQ_PARALLEL_PRODUCER_H

#import <Foundation/Foundation.h>
#import "Import/TTIOGenomicStreamSource.h"
#import "Core/TTIOProgressSink.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOFastqParallelProducer : NSObject

/** A batch producer over <code>path</code> (plain or gzip FASTQ) that
 *  parses on <code>threads</code> pool workers. Batch limits follow
 *  TTIOFastqReader: 0 = the default for each; the byte limit is
 *  approximate in this path (a slice cuts at the last whole record of
 *  the chunk that crossed it). */
+ (TTIOGenomicBatchProducer)pipelineProducerForPath:(NSString *)path
                                         sampleName:(NSString *)sampleName
                                         batchReads:(NSUInteger)batchReads
                                         batchBytes:(unsigned long long)batchBytes
                                            threads:(NSUInteger)threads
                                           progress:(nullable TTIOProgressBlock)progress;

/** Shard mode for a seekable plain file: the file splits into
 *  <code>threads</code> ranges on record boundaries, each range scans
 *  and parses on its own pool worker, and the ordered assembler hands
 *  batches back in file order. Falls back to the pipeline producer for
 *  tiny files or when no record fits the probe window. */
+ (TTIOGenomicBatchProducer)shardProducerForPath:(NSString *)path
                                      sampleName:(NSString *)sampleName
                                      batchReads:(NSUInteger)batchReads
                                      batchBytes:(unsigned long long)batchBytes
                                         threads:(NSUInteger)threads
                                        progress:(nullable TTIOProgressBlock)progress;

@end

NS_ASSUME_NONNULL_END

#endif
