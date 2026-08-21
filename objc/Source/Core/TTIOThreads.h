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

/** The pipeline byte budget: <code>explicit</code> > 0 wins, else the
 *  TTIO_MEMORY_BUDGET environment variable (bytes), else
 *  max(1 GiB, min(threads x blockBytes x 16, physical memory / 2)) -
 *  sixteen blockBytes per thread admits about one in-flight block per
 *  thread at the writer's half. The writer and the batch assembler
 *  each take half. */
+ (unsigned long long)resolveMemoryBudget:(nullable NSNumber *)explicitBytes
                                  threads:(NSUInteger)threads
                               blockBytes:(unsigned long long)blockBytes;

/** How many segments of one M94.Z V6 block to code at once, given how
 *  many blocks the pool keeps in flight: clamp(cores / workers, 2, 8).
 *
 *  Total concurrency wants to sit near the core count, and blocks are
 *  worth more than segments where there is a choice, because the work
 *  that is serial per block only overlaps across blocks. Segments are
 *  for the cores the blocks cannot reach — a writer near the end of a
 *  run, or one whose memory budget caps the blocks it can hold. That is
 *  what the floor of two is for.
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
