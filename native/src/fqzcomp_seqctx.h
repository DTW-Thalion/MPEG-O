/* native/src/fqzcomp_seqctx.h
 *
 * Qualities V5 body coder: the V4-shaped adaptive quality model with a
 * sequence-context field spliced into the context word. Body layout
 * (spec docs/superpowers/specs/2026-08-16-qualities-v5-design.md 2.1):
 *
 *   offset  size  field
 *     0       1   param_version = 1
 *     1       1   strategy_id (provenance only; decoders use the
 *                 explicit fields below)
 *     2       1   qbits
 *     3       1   qshift
 *     4       1   pbits
 *     5       1   pshift
 *     6       1   sbits
 *     7       1   reserved = 0
 *     8     var   range-coded quality stream (CRAM range coder,
 *                 one sm_model per context)
 *
 * Context word, low to high (spec 2):
 *   [ qctx : qbits ][ pos : pbits ][ seqctx : sbits ]
 *   qctx   = (qctx << qshift) + q, rolled after coding q, reset per read
 *   pos    = MIN((1<<pbits)-1, (len-1-i) >> pshift)
 *   seqctx = ((seqctx << 2) | bcode) masked, rolled BEFORE coding q_i
 *            (window includes the current base), reset per read
 *   bcode  = A/a:0 C/c:1 G/g:2 T/t:3, anything else 0
 *
 * The decoder consumes the same sequence bytes the encoder saw; the
 * caller (the M94.Z umbrella) guarantees they are the decoded
 * sequences channel of the same run.
 */
#ifndef TTIO_FQZCOMP_SEQCTX_H
#define TTIO_FQZCOMP_SEQCTX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ttio_seqctx_param {
    uint8_t strategy_id;   /* 5 or 6 */
    uint8_t qbits, qshift, pbits, pshift, sbits;
} ttio_seqctx_param;

/* The two shipped strategies (spec 2). */
extern const ttio_seqctx_param TTIO_SEQCTX_S5;   /* {5, 6,5,7,0,5} */
extern const ttio_seqctx_param TTIO_SEQCTX_S6;   /* {6, 8,5,4,0,6} */

#define TTIO_SEQCTX_MAX_CTX_BITS 18

#define TTIO_SEQCTX_ERR_ARGS     (-1)
#define TTIO_SEQCTX_ERR_OOM     (-2)
#define TTIO_SEQCTX_ERR_CORRUPT (-3)
#define TTIO_SEQCTX_ERR_NO_SEQ  (-30)
#define TTIO_SEQCTX_ERR_PARAM   (-31)

/* Encode n_qualities bytes as a V5 body (param block + RC stream).
 * seq_in must be n_qualities bytes. out_len: capacity in, bytes out.
 * sum(read_lengths) != n_qualities is TTIO_SEQCTX_ERR_ARGS. */
int ttio_fqz_seqctx_compress(
    const uint8_t  *qual_in,
    size_t          n_qualities,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *seq_in,
    const ttio_seqctx_param *pm,
    uint8_t        *out,
    size_t         *out_len);

/* Decode a V5 body. seq_in == NULL is TTIO_SEQCTX_ERR_NO_SEQ. */
int ttio_fqz_seqctx_uncompress(
    const uint8_t  *in,
    size_t          in_len,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *seq_in,
    uint8_t        *out,
    size_t          n_qualities);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_FQZCOMP_SEQCTX_H */
