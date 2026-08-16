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

@interface TTIOFloatDeltaZstd : NSObject

/** Encode little-endian float64 bytes (length % 8 == 0) into a
 *  self-contained FDZ1 stream. Returns nil on malloc/zstd failure. */
+ (nullable NSData *)encodeFloat64:(NSData *)values;

/** Decode an FDZ1 stream back to the exact float64 bytes. */
+ (nullable NSData *)decodeStream:(NSData *)stream error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
