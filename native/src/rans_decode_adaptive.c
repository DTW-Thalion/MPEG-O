/*
 * rans_decode_adaptive.c — adaptive M94.Z decoder using a Range Coder.
 *
 * NOTE: despite the file name, the implementation here is a Subbotin
 * Range Coder (arithmetic coder), NOT rANS. See encode kernel
 * comment for why we pivoted from rANS-Nx16.
 *
 * Decoder flow (single forward pass):
 *   1. Read 16 bytes lane_lengths header.
 *   2. Initialise 4 RC decoders, each consuming one lane stream.
 *   3. Initialise per-context (count, cum, T) tables.
 *   4. For each symbol i in order:
 *      - Compute M94.Z context (prev_q ring + position bucket +
 *        revcomp); map sparse -> dense via ctx_remap.
 *      - lane = i & 3
 *      - Look up T from slab[ctx_dense]
 *      - slot = rc_dec_get_freq(&rc[lane], T)
 *      - sym = inv_cum(cum, max_sym, slot)
 *      - Look up f = count[sym], c = cum[sym]
 *      - rc_dec_advance(&rc[lane], c, f)
 *      - symbols[i] = sym
 *      - update_ctx(slab[ctx_dense], sym)
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include "rans_adaptive_internal.h"
#include "rc_arith.h"
#include <stdlib.h>
#include <string.h>

static inline uint32_t read_le32(const uint8_t *p)
{
    return (uint32_t)p[0]
        | ((uint32_t)p[1] << 8)
        | ((uint32_t)p[2] << 16)
        | ((uint32_t)p[3] << 24);
}

/* M94.Z context formula — mirrors rans_decode_m94z.c. */
static inline uint32_t m94z_position_bucket(
    uint32_t position, uint32_t read_length, uint32_t pbits)
{
    if (pbits == 0) return 0;
    uint32_t n_buckets = 1u << pbits;
    if (read_length == 0 || position == 0) return 0;
    if (position >= read_length) return n_buckets - 1u;
    uint32_t b = (uint32_t)(((uint64_t)position * (uint64_t)n_buckets)
                            / (uint64_t)read_length);
    return (b < n_buckets - 1u) ? b : (n_buckets - 1u);
}

static inline uint32_t m94z_pack(
    uint32_t prev_q, uint32_t pos_bucket, uint32_t revcomp,
    uint32_t qbits, uint32_t pbits, uint32_t sloc)
{
    uint32_t qmask = (1u << qbits) - 1u;
    uint32_t pmask = (1u << pbits) - 1u;
    uint32_t smask = (1u << sloc) - 1u;
    uint32_t ctx = prev_q & qmask;
    ctx |= (pos_bucket & pmask) << qbits;
    ctx |= (revcomp & 1u) << (qbits + pbits);
    return ctx & smask;
}

int ttio_rans_decode_block_adaptive_m94z(
    const uint8_t           *compressed,
    size_t                   comp_len,
    uint16_t                 n_contexts,
    uint16_t                 max_sym,
    const ttio_m94z_params  *params,
    const uint16_t          *ctx_remap,
    const uint32_t          *read_lengths,
    size_t                   n_reads,
    const uint8_t           *revcomp_flags,
    uint16_t                 pad_ctx_dense,
    uint8_t                 *symbols,
    size_t                   n_symbols)
{
    if (!compressed || !params) return TTIO_RANS_ERR_PARAM;
    if (n_symbols > 0 && !symbols) return TTIO_RANS_ERR_PARAM;
    if (max_sym == 0 || max_sym > 256) return TTIO_RANS_ERR_PARAM;
    if (n_contexts == 0 || pad_ctx_dense >= n_contexts) return TTIO_RANS_ERR_PARAM;
    if (n_reads > 0 && (!read_lengths || !revcomp_flags))
        return TTIO_RANS_ERR_PARAM;
    if (params->sloc == 0 || params->sloc > 16) return TTIO_RANS_ERR_PARAM;
    if (params->qbits == 0 || params->qbits > 24) return TTIO_RANS_ERR_PARAM;
    if (params->pbits > 8) return TTIO_RANS_ERR_PARAM;

    if (n_symbols == 0) return TTIO_RANS_OK;

    /* Body header: 16 bytes lane_lengths. */
    if (comp_len < 16) return TTIO_RANS_ERR_CORRUPT;
    uint32_t lane_bytes[4];
    size_t total_lane_bytes = 0;
    for (int lane = 0; lane < 4; lane++) {
        lane_bytes[lane] = read_le32(compressed + lane * 4);
        total_lane_bytes += lane_bytes[lane];
    }
    if (comp_len < 16u + total_lane_bytes) return TTIO_RANS_ERR_CORRUPT;

    /* Initialise per-lane RC decoders. */
    ttio_rc_dec_t rc[4];
    size_t off = 16u;
    for (int lane = 0; lane < 4; lane++) {
        if (lane_bytes[lane] < 4u) {
            /* A lane with no symbols is allowed only if n_symbols ≤ lane.
             * For non-empty lane streams, we need >= 4 bytes for init. */
            if (lane_bytes[lane] != 0) return TTIO_RANS_ERR_CORRUPT;
            /* Mark as unused. */
            ttio_rc_dec_init(&rc[lane], NULL, 0);
            rc[lane].err = 0;
        } else {
            if (ttio_rc_dec_init(&rc[lane], compressed + off, lane_bytes[lane]) != 0) {
                return TTIO_RANS_ERR_CORRUPT;
            }
        }
        off += lane_bytes[lane];
    }

    /* Read sanity: n_reads sums to n_symbols. */
    if (n_reads > 0) {
        uint64_t sum = 0;
        for (size_t r = 0; r < n_reads; r++) sum += read_lengths[r];
        if (sum != n_symbols) return TTIO_RANS_ERR_PARAM;
    }

    /* Allocate adaptive table slab. */
    size_t slab_sz = ttio_adaptive_slab_size(n_contexts, max_sym);
    uint8_t *slab = (uint8_t *)malloc(slab_sz);
    if (!slab) return TTIO_RANS_ERR_ALLOC;
    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        ttio_adaptive_init_ctx(slab, ctx, max_sym);
    }

    /* M94.Z context-derivation state. */
    const uint32_t qbits = params->qbits;
    const uint32_t pbits = params->pbits;
    const uint32_t sloc  = params->sloc;
    const uint32_t shift = (qbits / 3u) > 0 ? (qbits / 3u) : 1u;
    const uint32_t qmask_local = (1u << qbits) - 1u;
    const uint32_t shift_mask  = (1u << shift) - 1u;

    size_t   read_idx = 0;
    uint32_t pos_in_read = 0;
    uint32_t cur_read_len = (n_reads > 0) ? read_lengths[0] : 0;
    uint32_t cur_revcomp  = (n_reads > 0) ? (uint32_t)revcomp_flags[0] : 0;
    size_t   cumulative_read_end = cur_read_len;
    uint32_t prev_q = 0;
    uint8_t  prev_sym = 0;

    /* Forward decode pass. */
    for (size_t i = 0; i < n_symbols; i++) {
        int lane = (int)(i & 3u);

        if (i > 0) {
            prev_q = ((prev_q << shift)
                      | ((uint32_t)prev_sym & shift_mask)) & qmask_local;
            pos_in_read += 1u;
        }
        if (i > 0 && i >= cumulative_read_end && read_idx + 1 < n_reads) {
            read_idx     += 1;
            pos_in_read   = 0;
            cur_read_len  = read_lengths[read_idx];
            cur_revcomp   = (uint32_t)revcomp_flags[read_idx];
            cumulative_read_end += cur_read_len;
            prev_q        = 0;
        }

        uint32_t pb = m94z_position_bucket(pos_in_read, cur_read_len, pbits);
        uint32_t ctx_sparse = m94z_pack(prev_q, pb, cur_revcomp & 1u,
                                        qbits, pbits, sloc);
        uint16_t ctx_dense;
        if (ctx_remap) {
            uint16_t mapped = ctx_remap[ctx_sparse];
            ctx_dense = (mapped < n_contexts) ? mapped : pad_ctx_dense;
        } else {
            ctx_dense = (ctx_sparse < n_contexts)
                ? (uint16_t)ctx_sparse : pad_ctx_dense;
        }

        const uint16_t *count = (const uint16_t *)(const void *)(slab
            + ttio_adaptive_count_offset(ctx_dense, max_sym));
        const uint32_t *cum   = (const uint32_t *)(const void *)(slab
            + ttio_adaptive_cum_offset(ctx_dense, max_sym));
        const uint16_t *Tp    = (const uint16_t *)(const void *)(slab
            + ttio_adaptive_T_offset(ctx_dense, max_sym));
        uint32_t T = *Tp;

        uint32_t slot = ttio_rc_dec_get_freq(&rc[lane], T);
        uint16_t sym = ttio_adaptive_inv_cum(cum, max_sym, slot);
        uint32_t f = count[sym];
        uint32_t c = cum[sym];

        ttio_rc_dec_advance(&rc[lane], c, f);
        if (rc[lane].err) {
            free(slab);
            return TTIO_RANS_ERR_CORRUPT;
        }

        symbols[i] = (uint8_t)sym;
        prev_sym = (uint8_t)sym;
        ttio_adaptive_update_ctx(slab, ctx_dense, max_sym, sym);
    }

    free(slab);
    return TTIO_RANS_OK;
}
