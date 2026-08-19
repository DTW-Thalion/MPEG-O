/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Writer state shared across the blocks of one blocks_v1 run
 * (format-spec 10.12): the chromosome-name to id map, grown in place as
 * blocks are written so ids stay stable across blocks, and the reference
 * MD5 computed once per run. +none gives the whole-channel writer's
 * per-run behaviour.
 */
@interface TTIOGenomicWriteContext : NSObject

/** Shared map, mutated by the writer; nil means assign ids per run. */
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSNumber *> *chromNameToId;

/** Precomputed reference digest; nil means compute from the run. */
@property (nonatomic, copy, nullable) NSData *referenceMD5;

/** Qualities strategy for FQZCOMP_NX16_Z blocks: -1 auto (the 3-way
 *  tune, default), 5/6 forced V5, TTIOM94ZHintV4Auto V4 with internal
 *  preset selection; the stream writer passes its per-run pin. */
@property (nonatomic, assign) NSInteger qualStrategyHint;

+ (instancetype)none;
+ (instancetype)contextWithChromNameToId:(nullable NSMutableDictionary<NSString *, NSNumber *> *)map
                            referenceMD5:(nullable NSData *)md5;

@end

NS_ASSUME_NONNULL_END
