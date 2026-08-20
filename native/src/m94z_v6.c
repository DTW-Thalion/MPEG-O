/* native/src/m94z_v6.c
 *
 * V6 single-chain qualities coder. Same sm_model + CRAM range coder
 * the V4 and V5 bodies use; only the context word differs, and the
 * chain covers one segment rather than a whole block.
 */
#include <stdlib.h>
#include <string.h>

#include "fqzcomp_seqctx.h"
#include "m94z_v6.h"
#include "rc_cram.h"
#include "sm_model.h"

/* Provisional: C = 12, matching the device envelope worked in the
 * design document. The Phase 1 ratio sweep replaces these. */
const ttio_v6_param TTIO_V6_DEFAULT = { 6, 5, 4, 4, 2 };

#define V6_NSYM 256

#ifndef MIN
#  define MIN(a,b) ((a)<(b)?(a):(b))
#endif

static int param_valid(const ttio_v6_param *pm) {
    if (!pm) return 0;
    if (pm->qshift > 8) return 0;
    if ((unsigned)pm->qbits + pm->pbits + pm->dbits > TTIO_V6_MAX_CTX_BITS)
        return 0;
    return 1;
}

static int lengths_sum(const uint32_t *lengths, size_t n_reads,
                       uint64_t *total) {
    uint64_t t = 0;
    for (size_t r = 0; r < n_reads; r++) t += lengths[r];
    *total = t;
    return 0;
}

/* Every segment starts from a cold model, so the per-context allocation
 * the V5 body does once per block would happen N times per block here.
 * One contiguous pool for the whole context array, filled from a
 * template, replaces n_ctx callocs. The layout matches sm_init exactly:
 * sentinel at F[0], symbols at F[1..nsym], terminal at F[nsym+1]. */
typedef struct {
    sm_model   *models;
    sm_symfreq *pool;
} v6_models;

static int models_init(v6_models *vm, size_t n_ctx) {
    const size_t stride = V6_NSYM + 2;
    sm_symfreq   tmpl[V6_NSYM + 2];

    vm->models = (sm_model *)malloc(n_ctx * sizeof(*vm->models));
    vm->pool = (sm_symfreq *)malloc(n_ctx * stride * sizeof(*vm->pool));
    if (!vm->models || !vm->pool) {
        free(vm->models);
        free(vm->pool);
        vm->models = NULL;
        vm->pool = NULL;
        return TTIO_SEQCTX_ERR_OOM;
    }

    memset(tmpl, 0, sizeof tmpl);
    tmpl[0].symbol = 0;
    tmpl[0].freq = (uint16_t)SM_MAX_FREQ;
    for (int i = 0; i < V6_NSYM; i++) {
        tmpl[i + 1].symbol = (uint16_t)i;
        tmpl[i + 1].freq = 1;
    }

    for (size_t c = 0; c < n_ctx; c++) {
        vm->models[c].nsym = V6_NSYM;
        vm->models[c].tot_freq = (uint32_t)V6_NSYM;
        vm->models[c].sentinel.freq = 0;
        vm->models[c].sentinel.symbol = 0;
        vm->models[c].F = vm->pool + c * stride;
        memcpy(vm->models[c].F, tmpl, sizeof tmpl);
    }
    return 0;
}

/* The models do not own their F arrays, so sm_destroy must not run. */
static void models_free(v6_models *vm) {
    free(vm->models);
    free(vm->pool);
    vm->models = NULL;
    vm->pool = NULL;
}

/* Shared coding loop. do_encode: qual is input and rc_e is active.
 * Otherwise qual is output and rc_d is active. */
static int code_pass(const ttio_v6_param *pm, uint8_t *qual,
                     const uint32_t *lengths, size_t n_reads,
                     rc_cram_encoder *rc_e, rc_cram_decoder *rc_d,
                     int do_encode) {
    size_t   n_ctx = (size_t)1 << (pm->qbits + pm->pbits + pm->dbits);
    v6_models vm;
    int      rc = models_init(&vm, n_ctx);
    if (rc != 0) return rc;

    const unsigned qmask = (1u << pm->qbits) - 1u;
    const unsigned pmax = (1u << pm->pbits) - 1u;
    const unsigned dmax = (1u << pm->dbits) - 1u;
    const int      ploc = pm->qbits;
    const int      dloc = pm->qbits + pm->pbits;

    size_t k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        unsigned qctx = 0, qp = 0, qpp = 0;
        uint32_t len = lengths[r];
        for (uint32_t i = 0; i < len; i++, k++) {
            unsigned pos = MIN(pmax, (unsigned)((len - 1 - i) >> pm->pshift));
            unsigned d = 0;
            if (i >= 2) {
                unsigned ad = qp > qpp ? qp - qpp : qpp - qp;
                d = MIN(dmax, ad);
            }
            unsigned ctx = (qctx & qmask) | (pos << ploc) | (d << dloc);
            unsigned q;
            if (do_encode) {
                q = qual[k];
                sm_encode(&vm.models[ctx], rc_e, (uint16_t)q);
            } else {
                q = sm_decode(&vm.models[ctx], rc_d);
                qual[k] = (uint8_t)q;
            }
            qctx = (qctx << pm->qshift) + q;
            qpp = qp;
            qp = q;
        }
    }

    models_free(&vm);
    return 0;
}

int ttio_v6_chain_encode(const ttio_v6_param *pm,
                         const uint8_t *qual,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len) {
    uint64_t n_qualities = 0;

    if (!param_valid(pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (!out || !out_len) return TTIO_SEQCTX_ERR_ARGS;
    if (n_reads > 0 && !lengths) return TTIO_SEQCTX_ERR_ARGS;
    lengths_sum(lengths, n_reads, &n_qualities);
    if (n_qualities > 0 && !qual) return TTIO_SEQCTX_ERR_ARGS;

    if (n_qualities == 0) {
        *out_len = 0;
        return 0;
    }

    rc_cram_encoder e;
    rc_cram_encoder_init(&e, out, *out_len);
    int rc = code_pass(pm, (uint8_t *)qual, lengths, n_reads, &e, NULL, 1);
    if (rc != 0) return rc;
    size_t body = rc_cram_encoder_finish(&e);
    if (e.err != 0) return TTIO_SEQCTX_ERR_ARGS;
    *out_len = body;
    return 0;
}

int ttio_v6_chain_decode(const ttio_v6_param *pm,
                         const uint8_t *in, size_t in_len,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *qual_out, size_t n_qualities) {
    uint64_t total = 0;

    if (!param_valid(pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (n_qualities == 0) return 0;
    if (!in || !qual_out || !lengths) return TTIO_SEQCTX_ERR_ARGS;
    lengths_sum(lengths, n_reads, &total);
    if (total != (uint64_t)n_qualities) return TTIO_SEQCTX_ERR_ARGS;

    rc_cram_decoder d;
    rc_cram_decoder_init(&d, in, in_len);
    return code_pass(pm, qual_out, lengths, n_reads, NULL, &d, 0);
}
