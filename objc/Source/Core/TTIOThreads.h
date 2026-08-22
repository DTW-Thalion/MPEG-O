/* The one thread knob of the SDK. TTIO_THREADS unset or 0 means
 * max(1, cores - 2); 1 is the serial path with no queue; N is the pool
 * size. Python: ttio._threads; Java: global.thalion.ttio.Threads.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_THREADS_H
#define TTIO_THREADS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTIOThreads : NSObject
+ (NSUInteger)resolve:(nullable NSNumber *)explicitCount;

/** Threads for an import pipeline when the caller names no count.
 *
 *  The pipeline byte budget is threads x blockBytes x 16 and the batch
 *  assembler and the writer take half each, so the thread knob sets
 *  residency as well as concurrency: one thread costs about a gibibyte
 *  of the budget at the 64 MiB block the importers use. On a 32 thread,
 *  31 GiB box the cores-2 default asks for 30 GiB, takes the half
 *  memory clamp instead, and a short read FASTQ import settles at about
 *  17.5 GiB resident.
 *
 *  Short reads are the case that reaches the clamp. A block of 150 bp
 *  records holds a million reads where the same block of HiFi holds a
 *  few thousand, so the pipeline runs out of memory well before it runs
 *  out of cores: measured on 27 M Illumina reads, 4 to 30 threads moved
 *  peak residency 9.8 -> 17.5 GiB for a throughput gain that stops
 *  paying in the single digits.
 *
 *  So cap the default at the count a quarter of physical memory
 *  affords. An explicit TTIO_THREADS is honoured as asked;
 *  TTIO_IMPORT_THREADS overrides this rule alone.
 *
 *  Python: ttio._threads.resolve_import_threads;
 *  Java: global.thalion.ttio.Threads.resolveImportThreads. */
+ (NSUInteger)resolveImportThreads;

/** The pipeline byte budget: <code>explicit</code> > 0 wins, else the
 *  TTIO_MEMORY_BUDGET environment variable (bytes), else
 *  max(1 GiB, min(threads x blockBytes x 16, physical memory / 2)) -
 *  sixteen blockBytes per thread admits about one in-flight block per
 *  thread at the writer's half. The writer and the batch assembler
 *  each take half. */
+ (unsigned long long)resolveMemoryBudget:(nullable NSNumber *)explicitBytes
                                  threads:(NSUInteger)threads
                               blockBytes:(unsigned long long)blockBytes;

/** Set the V6 segment thread count from the blocks in flight right now.
 *  A writer calls this as it submits, so the count follows the work
 *  rather than the pool's size; the pool restores the previous value
 *  when it closes. */
+ (void)applyV6SegmentThreadsForBlocksInFlight:(NSUInteger)blocksInFlight;

/** How many segments of one M94.Z V6 block to code at once, given how
 *  many blocks are in flight: clamp(cores / blocksInFlight, 2, cores).
 *
 *  Total concurrency wants to sit near the core count, and blocks are
 *  worth more than segments where there is a choice, because the work
 *  that is serial per block only overlaps across blocks. Segments are
 *  for the cores the blocks cannot reach — a writer near the end of a
 *  run, or one whose memory budget caps the blocks it can hold. That is
 *  what the floor of two is for.
 *
 *  TTIO_V6_SEGMENT_THREADS overrides the rule when it is a positive
 *  integer, so the split between blocks and segments can be measured
 *  rather than argued; see TtioGenomicWriteBench.
 *
 *  Python: ttio._threads.resolve_v6_segment_threads. */
+ (NSUInteger)resolveV6SegmentThreads:(NSUInteger)poolWorkers;
@end

/** A queue of N workers (nil queue when N <= 1) that, while it exists,
 *  stands the FQZCOMP auto-tune threads down and gives V6 a segment
 *  thread count of its own.
 *
 *  The two settings answer different questions and must not share one
 *  number. Auto-tune races three candidate encodes, so three per worker
 *  would oversubscribe and one is right. V6 has no candidates: left on
 *  the auto-tune knob it reads that same 1 and codes its segments one
 *  after another, which is the whole of its parallelism switched off
 *  under every writer that uses a pool. */
@interface TTIOThreadPool : NSObject
+ (instancetype)poolWithThreads:(NSUInteger)threads;
@property (nonatomic, readonly, nullable) NSOperationQueue *queue;
@property (nonatomic, readonly) NSUInteger threads;
- (void)close;
@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_THREADS_H */
