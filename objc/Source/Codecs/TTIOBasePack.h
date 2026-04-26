/*
 * TTIOBasePack.h — clean-room BASE_PACK genomic-sequence codec.
 *
 * 2-bit ACGT packing + sidecar mask for non-ACGT bytes. Clean-room
 * implementation; no htslib / CRAM tools-Java / jbzip source consulted.
 * Wire format matches the Python reference implementation
 * (python/src/ttio/codecs/base_pack.py) byte-for-byte; see
 * docs/codecs/base_pack.md (M84) for the format specification.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.base_pack
 *   Java:   global.thalion.ttio.codecs.BasePack
 *
 * Pack mapping (case-sensitive):
 *   'A' (0x41) -> 0b00
 *   'C' (0x43) -> 0b01
 *   'G' (0x47) -> 0b10
 *   'T' (0x54) -> 0b11
 *   anything else -> mask entry (placeholder 0b00 written to body)
 *
 * Bit order within byte is big-endian: the first base in the input
 * occupies the two highest-order bits of its body byte. Padding bits
 * in the final body byte (when len(input) % 4 != 0) are zero.
 *
 * Wire format (big-endian throughout, self-contained):
 *
 *   Offset  Size   Field
 *   ------  -----  ---------------------------------------------
 *   0       1      version            (0x00)
 *   1       4      original_length    (uint32 BE)
 *   5       4      packed_length      (uint32 BE = ceil(orig/4))
 *   9       4      mask_count         (uint32 BE)
 *   13      var    packed_body        (packed_length bytes)
 *   13+pl   var    mask               (mask_count x 5 bytes:
 *                                       uint32 BE position,
 *                                       uint8 original_byte)
 *
 * Total length = 13 + packed_length + 5 * mask_count bytes.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_BASE_PACK_H
#define TTIO_BASE_PACK_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Encode @p data with BASE_PACK + sidecar mask.
 *
 * @param data Input bytes. May be empty. Any byte value is accepted;
 *             uppercase A/C/G/T are packed into 2-bit slots, anything
 *             else gets a sidecar mask entry (case-sensitive — see
 *             HANDOFF.md M84 binding decision §81).
 *
 * @return An autoreleased NSData containing the self-contained encoded
 *         stream of length 13 + ceil(len(data)/4) + 5*mask_count.
 *         Never returns nil for valid inputs.
 */
NSData *TTIOBasePackEncode(NSData *data);

/**
 * Decode a stream produced by TTIOBasePackEncode.
 *
 * Validates the version byte, packed_length invariant, total stream
 * length, and that every mask position is in [0, original_length) and
 * strictly ascending.
 *
 * @param encoded Encoded byte stream.
 * @param error   On failure, populated with a domain-`@"TTIOBasePackError"`
 *                NSError describing the cause (truncated header, bad
 *                version byte, packed_length mismatch, total-length
 *                mismatch, mask position out of range, unsorted mask).
 *                May be NULL if the caller does not need the error.
 *
 * @return The original bytes on success, or nil on malformed input.
 */
NSData * _Nullable TTIOBasePackDecode(NSData *encoded,
                                      NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#endif /* TTIO_BASE_PACK_H */
