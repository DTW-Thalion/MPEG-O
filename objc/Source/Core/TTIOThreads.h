/* The one thread knob of the SDK. TTIO_THREADS unset or 0 means
 * max(1, cores - 8); 1 is the serial path with no queue; N is the pool
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
@end

/** A queue of N workers (nil queue when N <= 1) that stands the FQZCOMP
 *  auto-tune threads down while it exists. */
@interface TTIOThreadPool : NSObject
+ (instancetype)poolWithThreads:(NSUInteger)threads;
@property (nonatomic, readonly, nullable) NSOperationQueue *queue;
@property (nonatomic, readonly) NSUInteger threads;
- (void)close;
@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_THREADS_H */
