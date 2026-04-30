/*
 * TTIOFqzcompNx16.h — clean-room FQZCOMP_NX16 lossless quality codec.
 *
 * Mirrors python/src/ttio/codecs/fqzcomp_nx16.py byte-for-byte. See
 * docs/codecs/fqzcomp_nx16.md (M94) and the design spec
 * docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md §3
 * for the wire format. Codec id is TTIOCompressionFqzcompNx16 = 10.
 *
 * FQZCOMP_NX16 is a context-modeled adaptive arithmetic coder layered
 * on top of 4-way interleaved rANS. Each Phred quality byte is
 * predicted from a context vector
 *   (prev_q[0], prev_q[1], prev_q[2], position_bucket,
 *    revcomp_flag, length_bucket)
 * hashed (SplitMix64) into a 12-bit context-table index; each context
 * keeps a 256-entry uint16 frequency table that adapts after every
 * symbol with deterministic halve-with-floor-1 renormalisation at the
 * 4096-count boundary. The per-symbol M-normalisation (count→freq
 * sum=M=4096) reuses M83's ``TTIORansNormaliseFreqs`` verbatim — the
 * byte-parity of the FQZCOMP wire format depends on M83's exact
 * tie-break ordering.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.fqzcomp_nx16
 *   Java:   global.thalion.ttio.codecs.FqzcompNx16
 *
 * Wire format (little-endian throughout):
 *
 *   Header (54 + L bytes, L = compressed read-length-table size):
 *     0       4      magic "FQZN"
 *     4       1      version (0x01)
 *     5       1      flags
 *                      bits 0..3: context flags (revcomp/pos/length/prev_q)
 *                      bits 4..5: padding_count (0..3)
 *                      bits 6..7: reserved (must be 0)
 *     6       8      num_qualities      (uint64 LE)
 *     14      4      num_reads          (uint32 LE)
 *     18      4      rlt_compressed_len (uint32 LE) = L
 *     22      L      read_length_table  (rANS_ORDER0(read_lengths uint32[N] LE))
 *     22+L    16     context_model_params:
 *                      0   1  table_size_log2 (default 12)
 *                      1   1  learning_rate   (default 16)
 *                      2   2  max_count       (uint16 LE, default 4096)
 *                      4   1  freq_table_init (0 = uniform/all-ones)
 *                      5   4  hash_seed       (uint32 LE, default 0xC0FFEE)
 *                      9   7  reserved (zero)
 *     38+L    16     state_init[4]      (4 × uint32 LE)
 *
 *   Body:
 *     0       16     substream byte counts (4 × uint32 LE)
 *     16      …      round-robin-interleaved bytes from substreams
 *                    0,1,2,3 (zero-padded to equalise lengths)
 *
 *   Trailer (16 bytes):
 *     0       16     state_final[4]     (4 × uint32 LE)
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_FQZCOMP_NX16_H
#define TTIO_FQZCOMP_NX16_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TTIOFqzcompNx16ErrorDomain;

/**
 * Top-level FQZCOMP_NX16 codec.
 *
 * The codec is a pure function over (qualities, read_lengths,
 * revcomp_flags). The pipeline layer (TTIOSpectralDataset /
 * TTIOGenomicRun) is responsible for deriving these inputs from a
 * WrittenGenomicRun (read_lengths from run.lengths; revcomp_flags
 * from ``run.flags[i] & 16`` — the SAM REVERSE bit).
 */
@interface TTIOFqzcompNx16 : NSObject

/**
 * Encode a flat quality byte stream with the FQZCOMP_NX16 codec.
 *
 * @param qualities     Flat NSData of Phred quality bytes
 *                      (length == sum(readLengths)).
 * @param readLengths   Per-read read lengths as NSArray<NSNumber*>
 *                      (uint32-valued).
 * @param revcompFlags  Parallel NSArray<NSNumber*> of 0/1 — 1 means
 *                      the read carries the SAM REVERSE bit.
 * @param error         On failure populated with a
 *                      TTIOFqzcompNx16ErrorDomain error. May be NULL.
 *
 * @return Encoded byte stream (header + body + trailer), or nil on
 *         failure.
 */
+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                    error:(NSError * _Nullable *)error;

/**
 * Decode a byte stream produced by +encodeWithQualities:….
 *
 * @param data           Encoded byte stream.
 * @param revcompFlags   Per-read 0/1 flags. MUST match the flags the
 *                       encoder used; the wire format does NOT carry
 *                       them. Pass nil to use all-zero (forward).
 * @param error          On failure populated.
 *
 * @return Dictionary @{
 *           @"qualities":    NSData (flat byte stream),
 *           @"readLengths":  NSArray<NSNumber*> (uint32),
 *         } or nil on failure.
 */
+ (nullable NSDictionary *)decodeData:(NSData *)data
                          revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                                 error:(NSError * _Nullable *)error;

/** Convenience: decode with all-zero (forward) revcomp flags. */
+ (nullable NSDictionary *)decodeData:(NSData *)data
                                 error:(NSError * _Nullable *)error;

@end


/**
 * Codec header value class — exposed for the M86 read-side dispatcher
 * which needs num_qualities + num_reads + the read-length table before
 * driving the body decode.
 */
@interface TTIOFqzcompNx16CodecHeader : NSObject
@property (readonly) uint8_t  flags;
@property (readonly) uint64_t numQualities;
@property (readonly) uint32_t numReads;
@property (readonly) uint32_t rltCompressedLen;
@property (readonly, copy) NSData *readLengthTable;          // L bytes (rANS-encoded)
@property (readonly) uint8_t  contextTableSizeLog2;
@property (readonly) uint8_t  learningRate;
@property (readonly) uint16_t maxCount;
@property (readonly) uint8_t  freqTableInit;
@property (readonly) uint32_t contextHashSeed;
@property (readonly) uint32_t stateInit0;
@property (readonly) uint32_t stateInit1;
@property (readonly) uint32_t stateInit2;
@property (readonly) uint32_t stateInit3;

/** Parse the header from the start of @p blob. Writes the byte count
 *  consumed (54 + L) into @p outConsumed. */
+ (nullable instancetype)headerFromData:(NSData *)blob
                          bytesConsumed:(NSUInteger *)outConsumed
                                   error:(NSError * _Nullable *)error;
@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_FQZCOMP_NX16_H */
