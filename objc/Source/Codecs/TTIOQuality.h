/*
 * TTIOQuality.h — clean-room QUALITY_BINNED genomic quality-score codec.
 *
 * Fixed Illumina-8 8-bin Phred quantisation + 4-bit-packed bin
 * indices (big-endian within byte). Lossy by construction —
 * decode(encode(x)) == bin_centre[bin_of[x]], not x.
 *
 * Clean-room implementation; no htslib / CRUMBLE / NCBI SRA toolkit
 * source consulted. The 8-bin table ("Illumina-8 / CRUMBLE-style")
 * is documented in many published sources — Illumina's reduced-
 * representation guidance, James Bonfield's CRUMBLE paper
 * (Bioinformatics 2019), HTSlib's qual_quants field, NCBI SRA's
 * lossy.sra quality binning.
 *
 * Wire format mirrors python/src/ttio/codecs/quality.py byte-for-byte
 * (HANDOFF.md M85 §3):
 *
 *   Offset  Size   Field
 *   ------  -----  ---------------------------------------------
 *   0       1      version            (0x00)
 *   1       1      scheme_id          (0x00 = "illumina-8")
 *   2       4      original_length    (uint32 BE)
 *   6       var    packed_indices     (ceil(orig/2) bytes)
 *
 * Total length = 6 + ((original_length + 1) >> 1) bytes.
 *
 * Bin table (Illumina-8; HANDOFF binding decisions §91, §92, §93):
 *
 *   Bin  Phred range   Centre
 *   ---  -----------   ------
 *    0       0..1         0
 *    1       2..9         5
 *    2      10..19       15
 *    3      20..24       22
 *    4      25..29       27
 *    5      30..34       32
 *    6      35..39       37
 *    7     40..255       40    (saturates)
 *
 * Bit order within a body byte is **big-endian** (binding decision
 * §95): the first input quality occupies the high nibble. Padding
 * bits in the final body byte (when len(input) % 2 != 0) are zero
 * (binding decision §96); the decoder uses original_length to know
 * how many indices to consume.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.quality
 *   Java:   global.thalion.ttio.codecs.Quality
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_QUALITY_H
#define TTIO_QUALITY_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Encode @p data (Phred quality bytes) with QUALITY_BINNED.
 *
 * Maps each input byte through the Illumina-8 bin table, packs bin
 * indices 4-bits-per-index (big-endian within byte: first input
 * quality in the high nibble). Returns a self-contained NSData per
 * the wire format above.
 *
 * Lossy by construction:
 * decode(encode(x)) == bin_centre[bin_of[x]] for each byte x.
 *
 * @param data Input bytes — Phred quality scores. May be empty. Any
 *             byte value 0..255 is accepted; values > 40 saturate to
 *             bin 7 (centre 40).
 *
 * @return An autoreleased NSData containing the encoded stream of
 *         length 6 + ((len(data) + 1) >> 1). Never returns nil for
 *         valid inputs.
 */
NSData *TTIOQualityEncode(NSData *data);

/**
 * Decode a stream produced by TTIOQualityEncode.
 *
 * Validates strictly: the stream must be at least 6 bytes long, the
 * version byte must be 0x00, the scheme_id must be 0x00 (illumina-8),
 * and the total length must equal 6 + ceil(original_length / 2).
 *
 * @param encoded Encoded byte stream.
 * @param error   On failure, populated with a domain-`@"TTIOQualityError"`
 *                NSError describing the cause (truncated header, bad
 *                version byte, unknown scheme_id, length mismatch).
 *                May be NULL if the caller does not need the error.
 *
 * @return Output Phred bytes of length original_length on success
 *         (each byte the bin centre for the corresponding input
 *         byte's bin — lossy by construction), or nil on malformed
 *         input.
 */
NSData * _Nullable TTIOQualityDecode(NSData *encoded,
                                     NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#endif /* TTIO_QUALITY_H */
