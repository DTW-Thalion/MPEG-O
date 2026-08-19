/* SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOOrderedBatchAssembler
 *
 * Ordered fan-in for the parallel producers: slot producers run on a
 * pool in any order; the consumer receives their results strictly in
 * slot order. Submission never blocks; the caller (which is also the
 * consumer) bounds its own in-flight window and byte budget by pulling
 * before it submits, so the single-threaded submit/pull loop cannot
 * deadlock.
 */
#ifndef TTIO_ORDERED_BATCH_ASSEMBLER_H
#define TTIO_ORDERED_BATCH_ASSEMBLER_H

#import <Foundation/Foundation.h>
#import "Core/TTIOThreads.h"

@class TTIOWrittenGenomicRun;

NS_ASSUME_NONNULL_BEGIN

@interface TTIOOrderedBatchAssembler : NSObject

- (instancetype)initWithPool:(TTIOThreadPool *)pool;

/** Queue slot <code>seq</code>'s producer on the pool. Slots are
 *  submitted in increasing order starting at 0; never blocks. */
- (void)submitSlot:(NSUInteger)seq
          producer:(TTIOWrittenGenomicRun * _Nullable (^)(NSError * _Nullable __autoreleasing * _Nullable))producer;

/** No slot at or beyond <code>slotCount</code> will be submitted. */
- (void)finishAfterSlots:(NSUInteger)slotCount;

/** The next slot's result in order; blocks until it is ready. Returns
 *  nil with <code>*done = YES</code> after the final slot, nil with an
 *  error when that slot's producer failed. */
- (nullable TTIOWrittenGenomicRun *)nextBatchWithError:(NSError **)error
                                                  done:(BOOL *)done;

/* Two-level ordering for shard mode: results arrive from pool workers
 * as completed values under (major, minor); the consumer receives them
 * in lexicographic order. Submitting workers block while parked bytes
 * exceed the park budget, which is safe because the consumer is never
 * a submitter in this mode. */

/** Hand a completed result for (major, minor). Blocks the calling
 *  worker while parked bytes exceed <code>parkBudget</code>. */
- (void)submitReadyMajor:(NSUInteger)major
                   minor:(NSUInteger)minor
                     run:(nullable TTIOWrittenGenomicRun *)run
                   error:(nullable NSError *)err
          estimatedBytes:(unsigned long long)estimatedBytes
              parkBudget:(unsigned long long)parkBudget;

/** Major <code>major</code> has exactly <code>minorCount</code> minors. */
- (void)finishMajor:(NSUInteger)major afterMinors:(NSUInteger)minorCount;

/** No major at or beyond <code>majorCount</code> exists. */
- (void)finishAfterMajors:(NSUInteger)majorCount;

/** The next (major, minor) result in lexicographic order; blocks until
 *  ready. Semantics as -nextBatchWithError:done:. */
- (nullable TTIOWrittenGenomicRun *)nextOrderedBatchWithError:(NSError **)error
                                                         done:(BOOL *)done;

@end

NS_ASSUME_NONNULL_END

#endif
