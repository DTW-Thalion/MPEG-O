/*
 * TTIORefDiff.h — clean-room REF_DIFF reference-based sequence-diff codec.
 *
 * Mirrors python/src/ttio/codecs/ref_diff.py byte-for-byte. See
 * docs/codecs/ref_diff.md (M93) and the design spec
 * docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md §3
 * for the wire format. Codec id is TTIOCompressionRefDiff = 9.
 *
 * REF_DIFF is **context-aware**: encode/decode receive ``positions``,
 * ``cigars``, and the reference chromosome sequence alongside the read
 * sequences. The pipeline plumbing (per-run reference resolution +
 * embed) is the M86 layer's responsibility (see TTIOSpectralDataset).
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.ref_diff
 *   Java:   global.thalion.ttio.codecs.RefDiff
 *
 * Wire format (little-endian throughout):
 *
 *   Header (38 + N bytes, where N == utf8(reference_uri) length):
 *     Offset  Size   Field
 *     ------  -----  ---------------------------------------------
 *     0       4      magic "RDIF"
 *     4       1      version (0x01)
 *     5       3      reserved (zero)
 *     8       4      num_slices         (uint32 LE)
 *     12      8      total_reads        (uint64 LE)
 *     20      16     reference_md5      (raw bytes)
 *     36      2      reference_uri_len  (uint16 LE)
 *     38      N      reference_uri      (UTF-8)
 *
 *   Slice index (32 bytes per slice, num_slices entries):
 *     0       8      body_offset        (uint64 LE)
 *     8       4      body_length        (uint32 LE)
 *     12      8      first_position     (int64  LE)
 *     20      8      last_position      (int64  LE)
 *     28      4      num_reads          (uint32 LE)
 *
 *   Slice bodies: each body is a rANS_ORDER0-compressed stream of
 *   per-read records. Each record concatenates:
 *     * Bit-packed M-op flags (MSB-first), with each ``1`` flag
 *       followed by the substitution byte (8 bits, MSB-first).
 *       Padded with zero bits to the next byte boundary.
 *     * I-op bases verbatim.
 *     * S-op bases verbatim.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_REF_DIFF_H
#define TTIO_REF_DIFF_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TTIORefDiffErrorDomain;

/**
 * Top-level REF_DIFF codec.
 *
 * encode/decode are pure functions over per-read inputs. The pipeline
 * layer (TTIOSpectralDataset) resolves the reference chromosome and
 * splits the flat sequences buffer into per-read slices.
 */
@interface TTIORefDiff : NSObject

/**
 * Encode @p sequences (parallel with @p cigars and @p positions)
 * against @p referenceChromSeq.
 *
 * @param sequences          Array of read sequences (NSData of uppercase ACGT… bytes).
 * @param cigars             Parallel array of CIGAR strings.
 * @param positions          Parallel int64 NSData of 1-based reference positions
 *                           (length == sequences.count * sizeof(int64_t)).
 * @param referenceChromSeq  Full chromosome sequence (uppercase ACGTN…).
 * @param referenceMD5       Exactly 16-byte MD5 of the canonical reference.
 * @param referenceURI       URI matching the BAM @SQ M5 lookup key.
 * @param error              On failure, populated with a TTIORefDiffErrorDomain
 *                           error. May be NULL.
 *
 * @return Encoded byte stream (header + slice index + slice bodies),
 *         or nil on failure.
 */
+ (nullable NSData *)encodeWithSequences:(NSArray<NSData *> *)sequences
                                  cigars:(NSArray<NSString *> *)cigars
                               positions:(NSData *)positions
                      referenceChromSeq:(NSData *)referenceChromSeq
                            referenceMD5:(NSData *)referenceMD5
                            referenceURI:(NSString *)referenceURI
                                   error:(NSError * _Nullable *)error;

/**
 * Decode @p data into per-read sequences.
 *
 * @param data               Encoded byte stream produced by +encodeWithSequences:….
 * @param cigars             Per-read CIGAR strings (same order as encode).
 * @param positions          Per-read int64 LE positions NSData.
 * @param referenceChromSeq  Reference sequence (resolved via TTIOReferenceResolver).
 * @param error              On failure, populated with a TTIORefDiffErrorDomain
 *                           error.
 *
 * @return NSArray<NSData *> of per-read sequences, or nil on failure.
 */
+ (nullable NSArray<NSData *> *)decodeData:(NSData *)data
                                    cigars:(NSArray<NSString *> *)cigars
                                 positions:(NSData *)positions
                        referenceChromSeq:(NSData *)referenceChromSeq
                                     error:(NSError * _Nullable *)error;

@end

/**
 * Codec header value class — exposed for the M86 read-side dispatcher
 * which needs the reference URI + MD5 before invoking the resolver.
 */
@interface TTIORefDiffCodecHeader : NSObject
@property (readonly) uint32_t numSlices;
@property (readonly) uint64_t totalReads;
@property (readonly, copy) NSData *referenceMD5;       // exactly 16 bytes
@property (readonly, copy) NSString *referenceURI;     // UTF-8

/** Parse the header from the start of @p blob. On success returns a
 *  header object and writes the byte count consumed (38 + uri_len) into
 *  @p outConsumed. On malformed input returns nil and writes an error. */
+ (nullable instancetype)headerFromData:(NSData *)blob
                          bytesConsumed:(NSUInteger *)outConsumed
                                   error:(NSError * _Nullable *)error;

/** Pack into wire bytes. */
- (NSData *)packedData;

- (instancetype)initWithNumSlices:(uint32_t)numSlices
                       totalReads:(uint64_t)totalReads
                     referenceMD5:(NSData *)referenceMD5
                     referenceURI:(NSString *)referenceURI;
@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_REF_DIFF_H */
