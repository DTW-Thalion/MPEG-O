/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_SPECTRAL_BLOCK_INDEX_H
#define TTIO_SPECTRAL_BLOCK_INDEX_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Run/TTIOSpectralBlockIndex.h</p>
 *
 * <p>The decoded <code>blocks/index</code> of an MS run: one row per
 * FLOAT_DELTA_ZSTD block, giving the value range the block covers and,
 * for every signal channel, where that block's bytes are and which
 * codec produced them. It is the spectral counterpart of
 * <code>TTIOBlockTable</code> on a genomic run.</p>
 *
 * <p>Without it a consumer has to walk each channel's FDZ1 stream
 * reading 5-byte block headers to learn the same offsets. With it, one
 * compound read plans a range read or a parallel decode.</p>
 *
 * <p>A channel's recorded extent covers the block header as well as
 * the body, so the bytes at
 * <code>[offsetOf:at:, offsetOf:at: + lengthOf:at:)</code> are a
 * self-describing block.</p>
 *
 * <p>The group is written only for runs whose channels are stored with
 * codec 17, and only when every channel cut its blocks at the same
 * value boundaries. <code>+readFromRunGroup:error:</code> returns
 * <code>nil</code> for a run without it, which includes every MS run
 * written before the group existed.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 */
@interface TTIOSpectralBlockIndex : NSObject

/** Read <code>runGroup/blocks/index</code>; nil when the run has none. */
+ (nullable instancetype)readFromRunGroup:(id<TTIOStorageGroup>)runGroup
                                    error:(NSError **)error;

/** Number of blocks. */
@property (nonatomic, readonly) NSUInteger count;
/** Values in the run: the last block's value_start + n_values. */
@property (nonatomic, readonly) unsigned long long valueCount;
/** Channel names the table carries, in the order the writer declared. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *channelNames;

/** Index of the first value in a block. */
- (unsigned long long)valueStartAt:(NSUInteger)block;
/** Values in a block; the last block may be short. */
- (NSUInteger)valuesAt:(NSUInteger)block;
/** Byte offset of a channel's block within its signal dataset. */
- (unsigned long long)offsetOf:(NSString *)channel at:(NSUInteger)block;
/** Bytes of a channel's block, block header included. */
- (unsigned long long)lengthOf:(NSString *)channel at:(NSUInteger)block;
/** Codec id that produced a channel's block. */
- (NSUInteger)codecOf:(NSString *)channel at:(NSUInteger)block;

/** The block holding value <code>i</code>, or NSNotFound when out of
 *  range. */
- (NSUInteger)blockForValue:(unsigned long long)i;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_SPECTRAL_BLOCK_INDEX_H */
