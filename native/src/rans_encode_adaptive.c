/*
 * rans_encode_adaptive.c — adaptive M94.Z encoder using a Range Coder.
 *
 * NOTE: despite the file name, the implementation here is a Subbotin
 * Range Coder (arithmetic coder), NOT rANS. We initially designed
 * this as adaptive rANS-Nx16, but rANS's [L, M) state invariant
 * cannot be maintained when T_max approaches 2^16 (see memory
 * feedback_rans_nx16_variable_t_invariant). CRAM 3.1 fqzcomp_qual.c
 * uses the same Range Coder, which is why their T_max = 65519 works.
 *
 * Encoder flow (single forward pass, much simpler than rANS):
 *   1. Initialise 4 RC encoders (one per lane) writing to per-lane
 *      output buffers.
 *   2. Initialise per-context (count, cum, T) tables.
 *   3. For each symbol i in order:
 *      - lane = i & 3
 *      - ctx = contexts[i] (dense)
 *      - Look up f = count[sym], c = cum[sym], T from slab[ctx]
 *      - rc_encode(&rc[lane], c, f, T)
 *      - update_ctx(slab[ctx], sym)  // count[sym] += STEP, halve...
 *   4. Flush each RC (emit 4 trailing bytes per lane).
 *   5. Emit body: 16 bytes lane_lengths (uint32 LE × 4) +
 *      lane[0] bytes + lane[1] bytes + lane[2] bytes + lane[3] bytes.
 *
 * The wire-format header (magic + flags + RLT + max_sym etc.) is
 * built by the language wrapper, NOT here.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include "rans_adaptive_internal.h"
#include "rc_arith.h"
#include <stdlib.h>
#include <string.h>

static inline void write_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

int ttio_rans_encode_block_adaptive(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    uint16_t        max_sym,
    uint8_t        *out,
    size_t         *out_len)
{
    if (!out || !out_len) return TTIO_RANS_ERR_PARAM;
    if (max_sym == 0 || max_sym > 256) return TTIO_RANS_ERR_PARAM;
    if (n_contexts == 0) return TTIO_RANS_ERR_PARAM;
    if (n_symbols > 0 && (!symbols || !contexts)) return TTIO_RANS_ERR_PARAM;

    /* Body layout: 16 bytes lane_lengths + concatenated lane streams.
     * Empty input: 16 bytes header, all lengths zero. */
    if (n_symbols == 0) {
        if (*out_len < 16) return TTIO_RANS_ERR_PARAM;
        memset(out, 0, 16);
        *out_len = 16;
        return TTIO_RANS_OK;
    }

    /* Allocate context table slab. */
    size_t slab_sz = ttio_adaptive_slab_size(n_contexts, max_sym);
    uint8_t *slab = (uint8_t *)malloc(slab_sz);
    if (!slab) return TTIO_RANS_ERR_ALLOC;
    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        ttio_adaptive_init_ctx(slab, ctx, max_sym);
    }

    /* Per-lane output buffers. Estimate capacity: 1 byte per symbol
     * is generous (RC emits ~1 byte per symbol on average for
     * uniform input; worst case is bounded by entropy). Add 16-byte
     * tail for the flush. */
    size_t lane_cap = (n_symbols / 4u) + (n_symbols & 3u ? 1u : 0u) + 32u;
    /* Safer: allocate twice. RC output should never exceed input on
     * compressible data; a generous 4x safety factor. */
    lane_cap = lane_cap * 4u + 64u;
    uint8_t *lane_buf[4];
    uint8_t *lane_base[4];
    for (int lane = 0; lane < 4; lane++) {
        lane_buf[lane] = (uint8_t *)malloc(lane_cap);
        if (!lane_buf[lane]) {
            for (int j = 0; j < lane; j++) free(lane_buf[j]);
            free(slab);
            return TTIO_RANS_ERR_ALLOC;
        }
        lane_base[lane] = lane_buf[lane];
    }

    ttio_rc_enc_t rc[4];
    for (int lane = 0; lane < 4; lane++) {
        ttio_rc_enc_init(&rc[lane], lane_buf[lane], lane_cap);
    }

    /* Single forward pass. */
    for (size_t i = 0; i < n_symbols; i++) {
        uint16_t ctx = contexts[i];
        uint16_t sym = (uint16_t)symbols[i];
        if (ctx >= n_contexts || sym >= max_sym) {
            for (int lane = 0; lane < 4; lane++) free(lane_buf[lane]);
            free(slab);
            return TTIO_RANS_ERR_PARAM;
        }
        const uint16_t *count = (const uint16_t *)(const void *)(slab
            + ttio_adaptive_count_offset(ctx, max_sym));
        const uint32_t *cum   = (const uint32_t *)(const void *)(slab
            + ttio_adaptive_cum_offset(ctx, max_sym));
        const uint16_t *Tp    = (const uint16_t *)(const void *)(slab
            + ttio_adaptive_T_offset(ctx, max_sym));
        uint32_t f = count[sym];
        uint32_t c = cum[sym];
        uint32_t T = *Tp;

        int lane = (int)(i & 3u);
        ttio_rc_enc_encode(&rc[lane], c, f, T);
        if (rc[lane].err) {
            for (int l = 0; l < 4; l++) free(lane_buf[l]);
            free(slab);
            return TTIO_RANS_ERR_PARAM;  /* output buffer too small */
        }

        ttio_adaptive_update_ctx(slab, ctx, max_sym, sym);
    }
    free(slab);

    /* Flush each lane. */
    size_t lane_len[4];
    for (int lane = 0; lane < 4; lane++) {
        ttio_rc_enc_finish(&rc[lane]);
        if (rc[lane].err) {
            for (int l = 0; l < 4; l++) free(lane_buf[l]);
            return TTIO_RANS_ERR_PARAM;
        }
        lane_len[lane] = (size_t)(rc[lane].out - lane_base[lane]);
    }

    /* Emit body: 16 bytes lane_lengths + 4 lane streams. */
    size_t lane_total = 0;
    for (int lane = 0; lane < 4; lane++) lane_total += lane_len[lane];
    size_t body_len = 16u + lane_total;
    if (*out_len < body_len) {
        for (int lane = 0; lane < 4; lane++) free(lane_buf[lane]);
        return TTIO_RANS_ERR_PARAM;
    }
    uint8_t *p = out;
    for (int lane = 0; lane < 4; lane++) {
        write_le32(p + lane * 4, (uint32_t)lane_len[lane]);
    }
    p += 16;
    for (int lane = 0; lane < 4; lane++) {
        memcpy(p, lane_base[lane], lane_len[lane]);
        p += lane_len[lane];
    }

    *out_len = body_len;
    for (int lane = 0; lane < 4; lane++) free(lane_buf[lane]);
    return TTIO_RANS_OK;
}
