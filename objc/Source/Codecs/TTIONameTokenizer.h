/*
 * TTIONameTokenizer.h — clean-room NAME_TOKENIZED genomic read-name codec.
 *
 * Lean two-token-type columnar codec (M85 Phase B, M79 slot 8).
 * Each read name is tokenised into a sequence of numeric tokens
 * (digit-runs without leading zeros, value < 2^63) and string
 * tokens (everything else, including leading-zero digit-runs).
 * Per-column type detection across the batch picks columnar mode
 * (delta-encoded numerics + inline-dictionary-encoded strings) or
 * verbatim mode (length-prefixed bytes). See HANDOFF.md M85B §2-§4.
 *
 * Clean-room implementation; no htslib / CRAM tools-Java / SRA
 * toolkit / samtools / Bonfield 2022 reference source consulted at
 * any point. Inspired by CRAM 3.1 in spirit but NOT CRAM-3.1 wire
 * compatible.
 *
 * Wire format mirrors python/src/ttio/codecs/name_tokenizer.py
 * byte-for-byte (HANDOFF.md M85B §3):
 *
 *   Header (7 bytes):
 *     Offset  Size  Field
 *     ------  ----  ---------------------------------------------
 *     0       1     version            (0x00)
 *     1       1     scheme_id          (0x00 = "lean-columnar")
 *     2       1     mode               (0x00 columnar, 0x01 verbatim)
 *     3       4     n_reads            (uint32 BE)
 *
 *   Columnar body (mode = 0x00):
 *     n_columns (uint8)
 *     n_columns × uint8 type table (0=numeric, 1=string)
 *     per-column streams:
 *       Numeric: varint(first_value) + (n_reads-1) × svarint(delta)
 *       String:  n_reads × varint(code); if code == current dict
 *                size, follow with varint(byte_len) + bytes literal
 *
 *   Verbatim body (mode = 0x01):
 *     n_reads × { varint(byte_length), literal_bytes }
 *
 * Varints are unsigned LEB128. Signed deltas use zigzag-then-LEB128:
 *   encode(n) = (n << 1) ^ (n >> 63)   (arithmetic shift on int64).
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.name_tokenizer
 *   Java:   global.thalion.ttio.codecs.NameTokenizer
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_NAME_TOKENIZER_H
#define TTIO_NAME_TOKENIZER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Encode an ordered list of read names with NAME_TOKENIZED.
 *
 * Tokenises each name into numeric and string tokens, detects per-
 * column type, and emits either a columnar or verbatim stream per
 * the wire format above. Returns a self-contained NSData. Empty
 * @p names produces an 8-byte stream (header + n_columns = 0).
 *
 * Names must be 7-bit ASCII. Non-ASCII strings raise
 * NSInvalidArgumentException (pre-condition violation; mirrors
 * Python's ValueError).
 *
 * @param names Ordered list of read names. Must not be nil; may be
 *              empty. Each element must be a non-nil NSString
 *              containing only 7-bit ASCII.
 *
 * @return Encoded NSData. Never nil for valid input.
 */
NSData *TTIONameTokenizerEncode(NSArray<NSString *> *names);

/**
 * Decode a stream produced by TTIONameTokenizerEncode.
 *
 * Validates strictly: header length, version byte, scheme_id, mode
 * byte, well-formedness of all varints, total length consumed
 * matches input length. Returns the list of names in original
 * order on success.
 *
 * @param encoded Encoded byte stream. Must not be nil.
 * @param error   On failure, populated with a domain-
 *                @"TTIONameTokenizerError" NSError describing the
 *                cause. May be NULL if the caller does not need
 *                the error.
 *
 * @return Ordered NSArray of NSString on success, or nil on
 *         malformed input. Never crashes on bad input.
 */
NSArray<NSString *> * _Nullable TTIONameTokenizerDecode(
    NSData *encoded,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#endif /* TTIO_NAME_TOKENIZER_H */
