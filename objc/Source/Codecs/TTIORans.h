/*
 * TTIORans.h — clean-room rANS entropy codec (order-0 / order-1).
 *
 * Clean-room implementation of the range Asymmetric Numeral Systems
 * (rANS) codec from Jarek Duda, "Asymmetric numeral systems: entropy
 * coding combining speed of Huffman coding with compression rate of
 * arithmetic coding", arXiv:1311.2540, 2014.  Public domain
 * algorithm.  No htslib (or other third-party rANS) source code
 * consulted.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.rans
 *   Java:   global.thalion.ttio.codecs.Rans
 *
 * The wire format produced by `TTIORansEncode` is byte-identical to
 * the Python and Java implementations for the same input — see the
 * canonical test vectors under `objc/Tests/Fixtures/rans_*.bin`.
 *
 * Wire format (big-endian):
 *
 *   Offset  Size   Field
 *   ──────  ─────  ─────────────────────────────
 *   0       1      order (0x00 or 0x01)
 *   1       4      original_length      (uint32 BE)
 *   5       4      payload_length       (uint32 BE)
 *   9       var    frequency_table
 *                    order-0: 256 × uint32 BE = 1024 bytes
 *                    order-1: for each context 0..255:
 *                               uint16 BE  n_nonzero
 *                               n_nonzero × (uint8 sym, uint16 BE freq)
 *   9+ft    var    payload (rANS encoded bytes:
 *                  4-byte BE final state + renorm bytes in emit order)
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_RANS_H
#define TTIO_RANS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Encode @p data with rANS at the specified context order.
 *
 * @param data  Input byte string.  May be empty.
 * @param order 0 (marginal frequencies) or 1 (frequencies conditioned
 *              on the previous byte).  Any other value triggers an
 *              `NSInvalidArgumentException`.
 *
 * @return An autoreleased `NSData` containing the self-contained
 *         encoded stream (header + frequency table + rANS payload).
 *         Never returns nil for valid inputs.
 */
NSData *TTIORansEncode(NSData *data, int order);

/**
 * Decode a stream produced by `TTIORansEncode`.
 *
 * @param encoded Encoded byte stream.
 * @param error   On failure, populated with a domain-`@"TTIORansError"`
 *                NSError describing the cause (truncated header,
 *                unknown order byte, malformed frequency table, etc.).
 *                May be NULL if the caller does not need the error.
 *
 * @return The original data on success, or `nil` on malformed input.
 */
NSData * _Nullable TTIORansDecode(NSData *encoded,
                                  NSError * _Nullable * _Nullable error);

/**
 * Normalise a 256-entry count vector so it sums exactly to M=4096.
 *
 * Cross-language byte-exact contract — identical algorithm to
 * Python's ``ttio.codecs.rans._normalise_freqs`` and Java's
 * ``Rans.normaliseFreqs``. Reused verbatim by FQZCOMP_NX16 (M94)
 * for per-symbol M-normalisation of its adaptive count tables;
 * the byte-parity of the M94 wire format depends on this exact
 * tie-break ordering.
 *
 * Returns 0 on success, -1 if @p cnt is all-zero (cannot normalise
 * an empty alphabet to M).
 */
int TTIORansNormaliseFreqs(const uint64_t cnt[256], uint16_t freq[256]);

NS_ASSUME_NONNULL_END

#endif /* TTIO_RANS_H */
