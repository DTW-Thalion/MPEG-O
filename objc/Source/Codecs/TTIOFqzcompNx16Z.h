/*
 * TTIOFqzcompNx16Z.h — CRAM-mimic FQZCOMP_NX16 (rANS-Nx16) codec.
 *
 * M94.Z is a separate codec from M94 v1 (TTIOFqzcompNx16). It mirrors
 * python/src/ttio/codecs/fqzcomp_nx16_z.py byte-for-byte. See the
 * M94.Z design spec
 *   docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md
 * for the algorithm and wire format. Algorithm summary:
 *
 *   - L = 2^15, B = 16-bit renorm chunks, b·L = 2^31.
 *   - T = 4096 fixed total (power-of-2, T | b·L exactly).
 *   - N = 4 round-robin interleaved rANS states.
 *   - Static-per-block freq tables, built in a forward pre-pass and
 *     normalised once per active context.
 *   - Bit-pack context (CRAM-style):
 *       ctx = (prev_q & ((1<<qbits)-1))
 *           | ((pos_bucket & ((1<<pbits)-1)) << qbits)
 *           | ((revcomp & 1) << (qbits + pbits))
 *           & ((1<<sloc) - 1)
 *     Default qbits=12, pbits=2, sloc=14.
 *
 * Wire format (little-endian):
 *
 *   Header:
 *     0       4    magic "M94Z"
 *     4       1    version = 1
 *     5       1    flags
 *                    bits 0..3: reserved (0)
 *                    bits 4..5: pad_count (0..3)
 *                    bits 6..7: reserved (0)
 *     6       8    num_qualities      (uint64 LE)
 *     14      4    num_reads          (uint32 LE)
 *     18      4    rlt_compressed_len (uint32 LE) = R
 *     22      8    context_params (qbits, pbits, dbits, sloc, 4-byte pad)
 *     30      4    freq_tables_compressed_len (uint32 LE) = F
 *     34      R    read_length_table  (deflated uint32[N] LE)
 *     34+R    F    freq_tables_blob   (deflated; see below)
 *     34+R+F  16   state_init[4]      (4 × uint32 LE)
 *
 *   Body:
 *     +0      16   substream byte counts (4 × uint32 LE)
 *     +16     ...  concatenated per-substream byte buffers (LE 16-bit
 *                  pairs in chunk emit order)
 *
 *   Trailer (16 bytes):
 *     +0      16   state_final[4]     (4 × uint32 LE)
 *
 *   Freq tables blob (after deflate inflation):
 *     0       4    n_active_contexts (uint32 LE)
 *     for each active context (sorted ascending by ctx id):
 *       4     4    ctx_id            (uint32 LE)
 *       8     512  freq[256]         (256 × uint16 LE)
 *
 * Wire format V2 (version byte = 2; body produced by libttio_rans):
 *   Header: same fields as V1 EXCEPT no 16-byte state_init suffix
 *           (V2 body embeds final states at its own offset 0..15).
 *   Body  : raw output of ttio_rans_encode_block — self-contained
 *             [4 × uint32 LE final states][4 × uint32 LE lane sizes]
 *             [per-lane 16-bit LE chunks]
 *   No trailer.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.fqzcomp_nx16_z
 *   Java:   global.thalion.ttio.codecs.FqzcompNx16Z (M94.Z.4)
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_FQZCOMP_NX16_Z_H
#define TTIO_FQZCOMP_NX16_Z_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TTIOFqzcompNx16ZErrorDomain;

@interface TTIOFqzcompNx16Z : NSObject

/**
 * Encode a flat quality byte stream with the M94.Z codec.
 *
 * @param qualities     Flat NSData of Phred quality bytes (length ==
 *                      sum(readLengths)).
 * @param readLengths   Per-read read lengths as NSArray<NSNumber*>.
 * @param revcompFlags  Parallel NSArray<NSNumber*> of 0/1.
 * @param error         On failure populated.
 *
 * @return Encoded byte stream, or nil on failure.
 */
+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                    error:(NSError * _Nullable *)error;

/**
 * Encode with optional V2 native dispatch.
 *
 * Mirrors the four-arg variant but accepts an options dictionary. The
 * recognised key is:
 *
 *   - @c "preferNative" (NSNumber BOOL): when @c YES (and libttio_rans
 *     is linked in), emit a V2 wire-format stream (version byte = 2)
 *     whose body is produced by the native rANS encoder. When @c NO,
 *     force the V1 path. When the key is absent, the encoder consults
 *     the environment variable @c TTIO_M94Z_USE_NATIVE — values
 *     @c "1", @c "true", @c "yes", @c "on" (case-insensitive) enable
 *     V2 dispatch, otherwise V1 (the default).
 *
 * V2 streams are decoded transparently by @c +decodeData:revcompFlags:error:
 * (the version byte is auto-detected). V2 decode is currently
 * pure-ObjC because contexts in M94.Z are derived from previously-
 * decoded symbols, which the C library's pre-computed-contexts API
 * cannot supply (option E: V2 encode native, V2 decode pure-ObjC).
 */
+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                  options:(nullable NSDictionary<NSString *, id> *)options
                                    error:(NSError * _Nullable *)error;

/**
 * Decode a byte stream produced by +encodeWithQualities:.
 *
 * @param data           Encoded byte stream.
 * @param revcompFlags   Per-read 0/1 flags. MUST match the flags the
 *                       encoder used (the wire format does not carry
 *                       them). Pass nil for all-zero (forward).
 * @param error          On failure populated.
 *
 * @return Dictionary with @"qualities" (NSData) and @"readLengths"
 *         (NSArray<NSNumber*>), or nil on failure.
 */
+ (nullable NSDictionary *)decodeData:(NSData *)data
                          revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                                 error:(NSError * _Nullable *)error;

/** Convenience: decode with all-zero (forward) revcomp flags. */
+ (nullable NSDictionary *)decodeData:(NSData *)data
                                 error:(NSError * _Nullable *)error;

/**
 * Reports which rANS backend is wired into this build.
 *
 * Returns one of:
 *   - @"native-avx2", @"native-sse4.1", @"native-scalar" — when
 *     libttio_rans is linked in and its CPUID dispatch picked that kernel.
 *   - @"native-unknown" — defensive fallback if the library was linked in
 *     but kernel introspection returned an unexpected value.
 *   - @"pure-objc" — when libttio_rans is not linked; the codec uses the
 *     pure-ObjC implementation in this file.
 *
 * Backend selection only affects V2 (native-body) dispatch — see the
 * @c options dictionary on the encode method or the
 * @c TTIO_M94Z_USE_NATIVE environment variable. V1 streams are always
 * encoded and decoded via pure-ObjC. V2 decode is also pure-ObjC
 * (option E) because the C library cannot derive M94.Z contexts on
 * the fly — it requires a fully pre-computed contexts vector.
 */
+ (NSString *)backendName;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_FQZCOMP_NX16_Z_H */
