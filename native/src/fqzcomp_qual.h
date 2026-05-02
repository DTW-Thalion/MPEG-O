/* native/src/fqzcomp_qual.h
 *
 * CRAM 3.1 fqzcomp_qual port. Byte-compatible with
 * htscodecs/fqzcomp_qual_compress / _uncompress.
 *
 * The public API takes the flat qualities byte stream + per-read
 * metadata (read_lengths, flags) and produces a CRAM-3.1-compatible
 * compressed body. The body's per-block parameter header is encoded
 * inline (qbits/pbits/dbits/qshift/qloc/sloc/ploc/dloc/strategy_index).
 */
#ifndef TTIO_FQZCOMP_QUAL_H
#define TTIO_FQZCOMP_QUAL_H

#include <stddef.h>
#include <stdint.h>
#include "rc_cram.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Per-block parameter strategy. Mirrors htscodecs `fqz_param`. */
typedef struct ttio_fqz_param {
    uint8_t  context;     /* selector context bits */
    uint8_t  qbits;       /* quality history bits */
    uint8_t  qshift;      /* quality value shift */
    uint8_t  qloc;        /* qctx bit position in 16-bit context */
    uint8_t  pbits;       /* position bits */
    uint8_t  pshift;      /* position shift */
    uint8_t  ploc;        /* position bit position */
    uint8_t  dbits;       /* delta bits */
    uint8_t  dshift;      /* delta shift */
    uint8_t  dloc;        /* delta bit position */
    uint8_t  sbits;       /* selector bits */
    uint8_t  sloc;        /* selector bit position */
    uint8_t  do_qa;       /* quality-average split (0/1/2/4) */
    uint8_t  do_r2;       /* READ1/READ2 split (0/1) */
    uint8_t  do_dedup;    /* duplicate detection (0/1) */
    uint16_t max_sym;     /* max symbol value + 1 */
    uint8_t  qmap[256];   /* optional quality remap; identity if all 0..255 */
} ttio_fqz_param;

/* Per-block flags (encoded in the CRAM body header). */
typedef struct ttio_fqz_block_flags {
    uint8_t  has_qmap;
    uint8_t  has_selectors;
    uint8_t  fixed_strategy_index; /* 0..4, only used by encoder hint */
} ttio_fqz_block_flags;

/* Encode flat qualities to CRAM-byte-compatible body.
 *
 *   qual_in       — n_qualities bytes (Phred-33 ASCII)
 *   read_lengths  — n_reads ints, each the per-read quality length
 *   flags         — n_reads bytes; bit 4 (0x10) = SAM_REVERSE_FLAG (V3 convention)
 *   strategy_hint — -1 = auto-tune (Phase 3); 0..4 = use that preset (Phase 2 calls with 1)
 *   out, out_cap  — caller-owned output buffer
 *   out_len       — in: capacity; out: bytes written
 *
 * Returns 0 on success, negative on error.
 */
int ttio_fqzcomp_qual_compress(
    const uint8_t  *qual_in,
    size_t          n_qualities,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t        *out,
    size_t         *out_len);

/* Decode CRAM-byte-compatible body to flat qualities.
 *
 *   in, in_len    — compressed body bytes (parameter header inlined)
 *   read_lengths  — n_reads ints (decoder needs them; they live in the
 *                   M94.Z V4 outer header, not the CRAM body)
 *   flags         — n_reads bytes
 *   out           — caller-owned buffer of size n_qualities
 *   n_qualities   — total quality count (sum of read_lengths)
 *
 * Returns 0 on success, negative on error.
 */
int ttio_fqzcomp_qual_uncompress(
    const uint8_t  *in,
    size_t          in_len,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    uint8_t        *out,
    size_t          n_qualities);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_FQZCOMP_QUAL_H */
