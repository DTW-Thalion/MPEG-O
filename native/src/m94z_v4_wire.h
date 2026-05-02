/* native/src/m94z_v4_wire.h
 *
 * M94.Z V4 outer wire format: wraps a CRAM-byte-compatible
 * fqzcomp_qual body with our standard M94.Z header.
 *
 * Header format (per spec §4):
 *   offset  size   field
 *     0       4    magic = "M94Z"
 *     4       1    version = 4
 *     5       1    flags  (bit 0 = has_cram_body MUST=1; bits 4-5 = pad_count)
 *     6       8    num_qualities (uint64 LE)
 *    14       8    num_reads     (uint64 LE)
 *    22       4    rlt_compressed_len (uint32 LE)
 *    26    var R   read_length_table (deflated via zlib compress2 level 9)
 *  26+R       4    cram_body_len (uint32 LE)
 *  30+R   var      cram_body (CRAM-compatible from ttio_fqzcomp_qual_compress)
 *
 * Total = 30 + R + cram_body_len.
 *
 * Endianness: x86_64 / ARM64 are both little-endian, which matches
 * the on-the-wire LE convention used here. Byte-pack via memcpy.
 */
#ifndef TTIO_M94Z_V4_WIRE_H
#define TTIO_M94Z_V4_WIRE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TTIO_M94Z_V4_MAGIC "M94Z"
#define TTIO_M94Z_V4_VERSION 4

/* Pack a V4 stream: outer header + cram_body.
 *
 * Inputs:
 *   num_qualities, num_reads — for the header
 *   read_lengths             — input to compress as the RLT (deflated)
 *   pad_count                — 0..3 (V3 convention)
 *   cram_body, cram_body_len — output of ttio_fqzcomp_qual_compress
 *   out, out_cap             — caller-owned buffer
 *
 * Outputs:
 *   *out_len                 — in: capacity; out: bytes written
 *
 * Returns 0 on success, negative on error.
 */
int ttio_m94z_v4_pack(
    uint64_t          num_qualities,
    uint64_t          num_reads,
    const uint32_t   *read_lengths,
    uint8_t           pad_count,
    const uint8_t    *cram_body,
    size_t            cram_body_len,
    uint8_t          *out,
    size_t           *out_len);

/* Unpack a V4 stream: parse outer header, validate magic+version,
 * extract num_qualities / num_reads / read_lengths / cram_body.
 *
 *   in, in_len               — V4 stream bytes
 *   out_num_qualities        — total quality count from header
 *   out_num_reads            — read count from header
 *   out_read_lengths         — caller-allocated, num_reads entries;
 *                              decompressed RLT is written here
 *   out_pad_count            — flags bits 4-5
 *   out_cram_body            — pointer into `in` at the CRAM body
 *                              (lifetime tied to `in`)
 *   out_cram_body_len        — body length from header
 *
 * Returns 0 on success, negative on error.
 */
int ttio_m94z_v4_unpack(
    const uint8_t    *in,
    size_t            in_len,
    uint64_t         *out_num_qualities,
    uint64_t         *out_num_reads,
    uint32_t         *out_read_lengths,
    uint8_t          *out_pad_count,
    const uint8_t   **out_cram_body,
    size_t           *out_cram_body_len);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_M94Z_V4_WIRE_H */
