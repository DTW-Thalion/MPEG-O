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
 *   This codec is V4-only under v1.0: encode ALWAYS emits a V4 stream
 *   (version byte = 4) and decode accepts ONLY V4. Decode of any stream
 *   whose version byte is 1, 2, or 3 returns nil with error 203 ("no
 *   longer supported in v1.0"); the V1/V2/V3 emitters were DELETED in
 *   v1.0. The legacy layouts are retained below purely as forensic
 *   reference for understanding why such old streams are rejected — they
 *   are NEVER emitted.
 *
 * Wire format V4 (LIVE — version byte = 4; CRAM 3.1 fqzcomp port via
 * libttio_rans). This is the only format the codec emits and decodes:
 *   Outer header  : magic "M94Z", version=4, flags (bits 4-5 = pad_count),
 *                   num_qualities (uint64 LE), num_reads (uint64 LE),
 *                   rlt_compressed_len (uint32 LE), cram_body_len (uint32 LE).
 *   Body          : deflated RLT followed by htscodecs-byte-equal
 *                   fqzcomp_qual stream (auto-tune by default).
 *   See native/src/m94z_v4_wire.h for full layout.
 *
 * Legacy wire format V1 (DELETED in v1.0 — decode-rejected with error 203):
 *   Retained for forensic reference only; NOT emitted.
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
 * Legacy wire format V2 (DELETED in v1.0 — decode-rejected with error 203):
 *   Retained for forensic reference only; NOT emitted.
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
 * Encode, with an options dictionary.
 *
 * Mirrors the four-arg variant but accepts an options dictionary.
 *
 * Under v1.0 this codec is V4-only: encode ALWAYS emits a V4 (CRAM 3.1
 * fqzcomp_qual) stream and REQUIRES libttio_rans — it returns nil + an
 * error if the native library is not linked. There is no pure-ObjC
 * V1/V2 fallback.
 *
 * The only recognised key is:
 *
 *   - @c "v4StrategyHint" (NSNumber): -1 = auto-tune (default), 0..4 =
 *     explicit fqzcomp preset.
 *
 * Legacy keys such as @c "preferNative" / @c "preferV4" and the
 * V1/V2 context-table parameters (qbits/pbits/dbits/sloc) are accepted
 * and IGNORED for source/ABI compatibility; they no longer select a
 * wire format. The environment variables @c TTIO_M94Z_USE_NATIVE and
 * @c TTIO_M94Z_USE_NATIVE_STREAMING are likewise ignored.
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

/**
 * Convenience decode with all-zero (forward) revcomp flags.
 *
 * Equivalent to calling the explicit-flags variant with `revcompFlags
 * = nil`. Intended for callers that did not pass non-trivial revcomp
 * flags at encode time.
 *
 * @param data   Encoded byte stream.
 * @param error  Out-error on decode failure.
 * @return Dictionary with `@"qualities"` (`NSData`) and
 *         `@"readLengths"` (`NSArray<NSNumber *>`), or `nil` on
 *         failure.
 */
+ (nullable NSDictionary *)decodeData:(NSData *)data
                                 error:(NSError * _Nullable *)error;

/**
 * Encode with explicit V4 dispatch (CRAM 3.1 fqzcomp byte-compatible).
 *
 * Mirrors python/src/ttio/codecs/fqzcomp_nx16_z.py::encode(prefer_v4=True)
 * and global.thalion.ttio.codecs.FqzcompNx16Z.encode(opts.preferV4(true)).
 *
 * Returns an M94.Z V4 stream (version byte = 4) whose inner CRAM body
 * is byte-equal to htscodecs's fqzcomp_qual auto-tune output. Full M94Z
 * V4 streams are byte-equal across Python, Java, and ObjC.
 *
 * V4 is the default emit format when libttio_rans is linked.
 *
 * @param strategyHint -1 = auto-tune; 0..4 = explicit preset; default -1.
 * @param padCount 0..3 (carried in flags bits 4-5 of the V4 outer header,
 *                 V3 convention).
 */
+ (nullable NSData *)encodeV4WithQualities:(NSData *)qualities
                                readLengths:(NSArray<NSNumber *> *)readLengths
                               revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                               strategyHint:(NSInteger)strategyHint
                                   padCount:(uint8_t)padCount
                                      error:(NSError * _Nullable *)error;

/**
 * Decode a V4 M94.Z stream via libttio_rans.
 *
 * +decodeData:revcompFlags:error: dispatches to this internally when
 * encoded[4] == 4. Direct calls are useful for round-trip tests.
 *
 * Returns @{ @"qualities": NSData, @"readLengths": NSArray<NSNumber*> }
 * on success — read lengths are recovered from the V4 deflated RLT.
 */
+ (nullable NSDictionary *)decodeV4Data:(NSData *)data
                             revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
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
 * The codec is V4-only: when the backend is @"pure-objc" (libttio_rans
 * not linked) both encode and decode fail with an error, because V4 is
 * the only supported wire format and it is implemented entirely in the
 * native library.
 */
+ (NSString *)backendName;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_FQZCOMP_NX16_Z_H */
