/* native/src/m94z_v6.h
 *
 * M94.Z V6 qualities coder: segmented adaptive coding. A block's
 * qualities are split into N contiguous segments at read boundaries;
 * each segment is one independent chain with its own model and coder
 * state, so segments encode and decode in parallel and the output
 * bytes do not depend on how the work was scheduled.
 *
 * Wire format: docs/codecs/m94z_v6.md.
 *
 * Context word, low to high:
 *   [ qctx : qbits ][ pos : pbits ][ delta : dbits ]
 *   qctx  = (qctx << qshift) + q, rolled after coding q, reset per read
 *   pos   = MIN((1<<pbits)-1, (len-1-i) >> pshift)
 *   delta = MIN((1<<dbits)-1, |q_prev - q_prev2|), 0 for the first two
 *           symbols of a read, reset per read
 *
 * Unlike V5 this needs no sequence bytes: every field comes from the
 * qualities and the read-length table.
 *
 * Functions return 0 or a TTIO_SEQCTX_ERR_* value.
 */
#ifndef TTIO_M94Z_V6_H
#define TTIO_M94Z_V6_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t qbits, qshift, pbits, pshift, dbits;
} ttio_v6_param;

/* Provisional until the Phase 1 ratio sweep fixes it. */
extern const ttio_v6_param TTIO_V6_DEFAULT;

#define TTIO_V6_MAX_CTX_BITS 16

/* One segment. lengths/n_reads describe ONLY this segment's reads;
 * qual holds sum(lengths) bytes. *out_len is capacity in, bytes out.
 * The chain body is the bare range-coded stream: the parameters live
 * in the block body header, not here. */
int ttio_v6_chain_encode(const ttio_v6_param *pm,
                         const uint8_t *qual,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len);

int ttio_v6_chain_decode(const ttio_v6_param *pm,
                         const uint8_t *in, size_t in_len,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *qual_out, size_t n_qualities);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_M94Z_V6_H */
