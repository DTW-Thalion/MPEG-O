/*
 * TTIOFloatDeltaZstd.h
 * TTI-O Objective-C Implementation
 *
 * FLOAT_DELTA_ZSTD — lossless float64 channel codec (codec id 17).
 * Per block: none/delta on the uint64 bit view (chosen by exact size
 * comparison), byte-plane transpose, one zstd frame. Spec at
 * docs/superpowers/specs/2026-08-16-float-delta-codec-design.md.
 *
 * Per the spec's Option B decision, encoders MAY differ byte-wise
 * across languages; decoders MUST accept any conforming stream. The
 * shared golden fixture pins the decode side.
 *
 * Cross-language equivalents: Python ttio.codecs.float_delta_zstd,
 * Java global.thalion.ttio.codecs.FloatDeltaZstd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** One encoded FDZ1 block: the transform byte and the zstd body. */
@interface TTIOFDZEncodedBlock : NSObject
@property (nonatomic, readonly) uint8_t transform;
@property (nonatomic, readonly, copy) NSData *body;
- (instancetype)initWithTransform:(uint8_t)transform body:(NSData *)body;
@end

/** The block directory of an FDZ1 stream read from its header and the
 *  block headers only: where each block's body lies and how many values
 *  it holds, so a range read touches only the blocks it needs. */
@interface TTIOFDZBlockTable : NSObject
@property (nonatomic, readonly) uint64_t nValues;
@property (nonatomic, readonly) uint32_t blockSize;
@property (nonatomic, readonly) uint32_t nBlocks;
- (uint64_t)offsetAt:(NSUInteger)block;
- (uint8_t)transformAt:(NSUInteger)block;
- (uint32_t)lengthAt:(NSUInteger)block;
/** Values in block <code>k</code> (the last block may be short). */
- (NSUInteger)blockValues:(NSUInteger)k;
@end

/** Reads <code>count</code> bytes at <code>offset</code> of the stream;
 *  nil on failure. */
typedef NSData * _Nullable (^TTIOFDZByteRangeReader)(NSUInteger offset, NSUInteger count);

@interface TTIOFloatDeltaZstd : NSObject

/** Values per block, 1 048 576. */
+ (NSUInteger)blockSize;
/** The 22-byte stream header for <code>nValues</code> values in
 *  <code>nBlocks</code> blocks. */
+ (NSData *)headerBytesForValues:(uint64_t)nValues blocks:(uint32_t)nBlocks;
/** Encode one block of float64 values (at most blockSize). */
+ (nullable TTIOFDZEncodedBlock *)encodeBlock:(NSData *)float64Values;
/** The on-stream bytes of a block: transform, body length, body. */
+ (NSData *)blockBytes:(TTIOFDZEncodedBlock *)block;
/** Read the block directory through a byte-range reader. */
+ (nullable TTIOFDZBlockTable *)readBlockTableWithReader:(TTIOFDZByteRangeReader)reader
                                                    error:(NSError **)error;
/** Decode block <code>k</code> to float64 bytes through a byte-range reader. */
+ (nullable NSData *)decodeBlock:(NSUInteger)k
                           table:(TTIOFDZBlockTable *)table
                          reader:(TTIOFDZByteRangeReader)reader
                           error:(NSError **)error;

/** Encode little-endian float64 bytes (length % 8 == 0) into a
 *  self-contained FDZ1 stream. Returns nil on malloc/zstd failure. */
+ (nullable NSData *)encodeFloat64:(NSData *)values;

/** Decode an FDZ1 stream back to the exact float64 bytes. */
+ (nullable NSData *)decodeStream:(NSData *)stream error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
