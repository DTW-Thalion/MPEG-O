/* SPDX-License-Identifier: LGPL-3.0-or-later */
#import "Import/TTIOOrderedBatchAssembler.h"
#import "Genomics/TTIOWrittenGenomicRun.h"

@interface TTIOAssemblerSlot : NSObject
@property (nonatomic, strong, nullable) TTIOWrittenGenomicRun *run;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic) unsigned long long estimatedBytes;
@property (nonatomic) BOOL done;
@end

@implementation TTIOAssemblerSlot
@end

@implementation TTIOOrderedBatchAssembler {
    TTIOThreadPool *_pool;
    NSMutableDictionary<NSNumber *, TTIOAssemblerSlot *> *_slots;
    NSCondition *_cond;
    NSUInteger _consumeNext;
    NSUInteger _slotCount;
    BOOL _finished;
    /* Two-level mode. */
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, TTIOAssemblerSlot *> *> *_majors;
    NSMutableDictionary<NSNumber *, NSNumber *> *_majorCounts;
    unsigned long long _parkedBytes;
    NSUInteger _curMajor;
    NSUInteger _curMinor;
    NSUInteger _majorCount;
    BOOL _majorsFinished;
}

- (instancetype)initWithPool:(TTIOThreadPool *)pool
{
    if ((self = [super init])) {
        _pool = pool;
        _slots = [NSMutableDictionary dictionary];
        _cond = [NSCondition new];
        _majors = [NSMutableDictionary dictionary];
        _majorCounts = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)submitSlot:(NSUInteger)seq
          producer:(TTIOWrittenGenomicRun * (^)(NSError * __autoreleasing *))producer
{
    TTIOAssemblerSlot *slot = [TTIOAssemblerSlot new];
    [_cond lock];
    _slots[@(seq)] = slot;
    [_cond unlock];
    NSCondition *cond = _cond;
    [_pool.queue addOperationWithBlock:^{
        TTIOWrittenGenomicRun *run = nil;
        NSError *err = nil;
        @try {
            run = producer(&err);
        } @catch (NSException *ex) {
            run = nil;
            err = [NSError errorWithDomain:@"TTIOOrderedBatchAssembler" code:1
                                  userInfo:@{ NSLocalizedDescriptionKey :
                                              [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason] }];
        }
        [cond lock];
        slot.run = run;
        slot.error = err;
        slot.done = YES;
        [cond broadcast];
        [cond unlock];
    }];
}

- (void)finishAfterSlots:(NSUInteger)slotCount
{
    [_cond lock];
    _slotCount = slotCount;
    _finished = YES;
    [_cond broadcast];
    [_cond unlock];
}

- (TTIOWrittenGenomicRun *)nextBatchWithError:(NSError **)error done:(BOOL *)done
{
    if (done) *done = NO;
    [_cond lock];
    while (1) {
        if (_finished && _consumeNext >= _slotCount && _slots[@(_consumeNext)] == nil) {
            [_cond unlock];
            if (done) *done = YES;
            return nil;
        }
        TTIOAssemblerSlot *slot = _slots[@(_consumeNext)];
        if (slot != nil && slot.done) {
            [_slots removeObjectForKey:@(_consumeNext)];
            _consumeNext++;
            [_cond broadcast];
            [_cond unlock];
            if (slot.error != nil || slot.run == nil) {
                if (error) *error = slot.error;
                return nil;
            }
            return slot.run;
        }
        [_cond wait];
    }
}

- (void)submitReadyMajor:(NSUInteger)major
                   minor:(NSUInteger)minor
                     run:(TTIOWrittenGenomicRun *)run
                   error:(NSError *)err
          estimatedBytes:(unsigned long long)estimatedBytes
              parkBudget:(unsigned long long)parkBudget
{
    TTIOAssemblerSlot *slot = [TTIOAssemblerSlot new];
    slot.run = run;
    slot.error = err;
    slot.done = YES;
    [_cond lock];
    /* The consumer never submits in this mode, so a worker may wait
     * for it to drain the park. Never park the slot the consumer is
     * waiting for. */
    while (_parkedBytes > parkBudget
           && !(major == _curMajor && minor == _curMinor)) {
        [_cond wait];
    }
    NSMutableDictionary *minors = _majors[@(major)];
    if (minors == nil) {
        minors = [NSMutableDictionary dictionary];
        _majors[@(major)] = minors;
    }
    minors[@(minor)] = slot;
    _parkedBytes += estimatedBytes;
    slot.estimatedBytes = estimatedBytes;
    [_cond broadcast];
    [_cond unlock];
}

- (void)finishMajor:(NSUInteger)major afterMinors:(NSUInteger)minorCount
{
    [_cond lock];
    _majorCounts[@(major)] = @(minorCount);
    [_cond broadcast];
    [_cond unlock];
}

- (void)finishAfterMajors:(NSUInteger)majorCount
{
    [_cond lock];
    _majorCount = majorCount;
    _majorsFinished = YES;
    [_cond broadcast];
    [_cond unlock];
}

- (TTIOWrittenGenomicRun *)nextOrderedBatchWithError:(NSError **)error done:(BOOL *)done
{
    if (done) *done = NO;
    [_cond lock];
    while (1) {
        /* Advance past finished majors. */
        NSNumber *count = _majorCounts[@(_curMajor)];
        if (count != nil && _curMinor >= count.unsignedIntegerValue) {
            [_majors removeObjectForKey:@(_curMajor)];
            _curMajor++;
            _curMinor = 0;
            continue;
        }
        if (_majorsFinished && _curMajor >= _majorCount) {
            [_cond unlock];
            if (done) *done = YES;
            return nil;
        }
        TTIOAssemblerSlot *slot = _majors[@(_curMajor)][@(_curMinor)];
        if (slot != nil && slot.done) {
            [_majors[@(_curMajor)] removeObjectForKey:@(_curMinor)];
            _curMinor++;
            _parkedBytes -= slot.estimatedBytes <= _parkedBytes ? slot.estimatedBytes : _parkedBytes;
            [_cond broadcast];
            [_cond unlock];
            if (slot.error != nil || slot.run == nil) {
                if (error) *error = slot.error;
                return nil;
            }
            return slot.run;
        }
        [_cond wait];
    }
}

@end
