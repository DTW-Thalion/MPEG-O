/* native/src/fqzcomp_seqctx.c
 *
 * Qualities V5 body coder. See fqzcomp_seqctx.h for the body layout
 * and context-word definition. The model and coder are the same
 * sm_model + CRAM range coder the V4 body uses; only the context
 * word differs.
 */
#include <stdlib.h>
#include <string.h>

#include "fqzcomp_seqctx.h"
#include "rc_cram.h"
#include "sm_model.h"

const ttio_seqctx_param TTIO_SEQCTX_S5 = { 5, 6, 5, 7, 0, 5 };
const ttio_seqctx_param TTIO_SEQCTX_S6 = { 6, 8, 5, 4, 0, 6 };

#define SEQCTX_HDR_LEN 8

#ifndef MIN
#  define MIN(a,b) ((a)<(b)?(a):(b))
#endif

/* base byte -> 2-bit code (A/a and everything unrecognised map to 0). */
static const uint8_t bcode_tab[256] = {
    ['C'] = 1, ['G'] = 2, ['T'] = 3,
    ['c'] = 1, ['g'] = 2, ['t'] = 3,
};

static int param_valid(const ttio_seqctx_param *pm) {
    if (!pm) return 0;
    if (pm->sbits < 2) return 0;
    if (pm->qshift > 8) return 0;
    if ((int)pm->qbits + pm->pbits + pm->sbits > TTIO_SEQCTX_MAX_CTX_BITS)
        return 0;
    return 1;
}

static int lengths_sum_ok(const uint32_t *read_lengths, size_t n_reads,
                          size_t n_qualities) {
    uint64_t total = 0;
    for (size_t r = 0; r < n_reads; r++) total += read_lengths[r];
    return total == (uint64_t)n_qualities;
}

/* Shared coding loop. do_encode: qual is input, rc_e active.
 * Otherwise qual is output, rc_d active. Returns 0 or an error. */
static int code_pass(const ttio_seqctx_param *pm,
                     uint8_t *qual, const uint8_t *seq,
                     const uint32_t *read_lengths, size_t n_reads,
                     rc_cram_encoder *rc_e, rc_cram_decoder *rc_d,
                     int do_encode) {
    size_t n_ctx = (size_t)1 << (pm->qbits + pm->pbits + pm->sbits);
    sm_model *models = (sm_model *)malloc(n_ctx * sizeof(*models));
    if (!models) return TTIO_SEQCTX_ERR_OOM;
    for (size_t i = 0; i < n_ctx; i++) {
        if (sm_init(&models[i], 256, 256) != 0) {
            for (size_t j = 0; j < i; j++) sm_destroy(&models[j]);
            free(models);
            return TTIO_SEQCTX_ERR_OOM;
        }
    }

    const unsigned qmask = (1u << pm->qbits) - 1u;
    const unsigned smask = (1u << pm->sbits) - 1u;
    const unsigned pmax  = (1u << pm->pbits) - 1u;
    const int ploc = pm->qbits;
    const int xloc = pm->qbits + pm->pbits;

    int rc = 0;
    size_t k = 0;
    for (size_t r = 0; r < n_reads && rc == 0; r++) {
        unsigned qctx = 0, seqctx = 0;
        uint32_t len = read_lengths[r];
        for (uint32_t i = 0; i < len; i++, k++) {
            seqctx = ((seqctx << 2) | bcode_tab[seq[k]]) & smask;
            unsigned pos = MIN(pmax, (unsigned)((len - 1 - i) >> pm->pshift));
            unsigned ctx = (qctx & qmask)
                         | (pos << ploc)
                         | (seqctx << xloc);
            unsigned q;
            if (do_encode) {
                q = qual[k];
                sm_encode(&models[ctx], rc_e, (uint16_t)q);
            } else {
                q = sm_decode(&models[ctx], rc_d);
                qual[k] = (uint8_t)q;
            }
            qctx = (qctx << pm->qshift) + q;
        }
    }

    for (size_t i = 0; i < n_ctx; i++) sm_destroy(&models[i]);
    free(models);
    return rc;
}

int ttio_fqz_seqctx_compress(
    const uint8_t  *qual_in,
    size_t          n_qualities,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *seq_in,
    const ttio_seqctx_param *pm,
    uint8_t        *out,
    size_t         *out_len) {
    if (!param_valid(pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (!out || !out_len || *out_len < SEQCTX_HDR_LEN)
        return TTIO_SEQCTX_ERR_ARGS;
    if (n_qualities > 0) {
        if (!qual_in || !read_lengths) return TTIO_SEQCTX_ERR_ARGS;
        if (!seq_in) return TTIO_SEQCTX_ERR_NO_SEQ;
        if (!lengths_sum_ok(read_lengths, n_reads, n_qualities))
            return TTIO_SEQCTX_ERR_ARGS;
    }


    out[0] = 1;
    out[1] = pm->strategy_id;
    out[2] = pm->qbits;
    out[3] = pm->qshift;
    out[4] = pm->pbits;
    out[5] = pm->pshift;
    out[6] = pm->sbits;
    out[7] = 0;

    if (n_qualities == 0) {
        *out_len = SEQCTX_HDR_LEN;
        return 0;
    }

    rc_cram_encoder e;
    rc_cram_encoder_init(&e, out + SEQCTX_HDR_LEN,
                         *out_len - SEQCTX_HDR_LEN);
    int rc = code_pass(pm, (uint8_t *)qual_in, seq_in,
                       read_lengths, n_reads, &e, NULL, 1);
    if (rc != 0) return rc;
    size_t body = rc_cram_encoder_finish(&e);
    *out_len = SEQCTX_HDR_LEN + body;
    return 0;
}

int ttio_fqz_seqctx_uncompress(
    const uint8_t  *in,
    size_t          in_len,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *seq_in,
    uint8_t        *out,
    size_t          n_qualities) {
    if (!in || in_len < SEQCTX_HDR_LEN) return TTIO_SEQCTX_ERR_CORRUPT;
    if (in[0] != 1) return TTIO_SEQCTX_ERR_CORRUPT;
    ttio_seqctx_param pm = {
        .strategy_id = in[1],
        .qbits = in[2], .qshift = in[3],
        .pbits = in[4], .pshift = in[5],
        .sbits = in[6],
    };
    if (in[7] != 0) return TTIO_SEQCTX_ERR_CORRUPT;
    if (!param_valid(&pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (n_qualities == 0) return 0;
    if (!out || !read_lengths) return TTIO_SEQCTX_ERR_ARGS;
    if (!seq_in) return TTIO_SEQCTX_ERR_NO_SEQ;
    if (!lengths_sum_ok(read_lengths, n_reads, n_qualities))
        return TTIO_SEQCTX_ERR_ARGS;


    rc_cram_decoder d;
    rc_cram_decoder_init(&d, in + SEQCTX_HDR_LEN, in_len - SEQCTX_HDR_LEN);
    return code_pass(&pm, out, seq_in, read_lengths, n_reads,
                     NULL, &d, 0);
}
