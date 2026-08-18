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
