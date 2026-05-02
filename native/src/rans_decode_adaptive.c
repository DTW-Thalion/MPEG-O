/*
 * rans_decode_adaptive.c — adaptive M94.Z decoder with inline
 * M94.Z context derivation.
 *
 * Mirrors rans_decode_m94z.c (Task #81) but uses adaptive freq
 * updates instead of pre-computed static freq tables. The adaptive
 * symmetry lemma (spec §2.4) guarantees encoder/decoder maintain
 * identical (count[][], T[]) trajectories.
 *
 * Forward decode pass: derive context inline from prev_q ring +
 * pos_in_read + revcomp; lookup in current adaptive table; decode
 * symbol; update table.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include "rans_adaptive_internal.h"
#include <stdlib.h>
#include <string.h>

static inline uint32_t read_le32(const uint8_t *p)
{
    return (uint32_t)p[0]
        | ((uint32_t)p[1] << 8)
        | ((uint32_t)p[2] << 16)
        | ((uint32_t)p[3] << 24);
}

static inline uint16_t read_le16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
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

    /* Body header: 16 bytes substream_lengths + lane bytes + 16
     * bytes state_final. */
    if (comp_len < 32) return TTIO_RANS_ERR_CORRUPT;
    uint32_t lane_bytes[4];
    size_t total_lane_bytes = 0;
    for (int lane = 0; lane < 4; lane++) {
        lane_bytes[lane] = read_le32(compressed + lane * 4);
        total_lane_bytes += lane_bytes[lane];
    }
    if (comp_len < 16u + total_lane_bytes + 16u) return TTIO_RANS_ERR_CORRUPT;

    const uint8_t *lane_data[4];
    size_t lane_pos[4] = {0, 0, 0, 0};
    size_t off = 16u;
    for (int lane = 0; lane < 4; lane++) {
        lane_data[lane] = compressed + off;
        off += lane_bytes[lane];
    }
    const uint8_t *state_final_p = compressed + off;

    /* Read sanity: n_reads sums to n_symbols. */
    if (n_reads > 0) {
        uint64_t sum = 0;
        for (size_t r = 0; r < n_reads; r++) sum += read_lengths[r];
        if (sum != n_symbols) return TTIO_RANS_ERR_PARAM;
    }

    /* Initial state: state_final from wire (per wire format §5.3,
     * state_final is the encoder's final state which IS the decoder's
     * starting state). */
    uint64_t state[4];
    for (int lane = 0; lane < 4; lane++) {
        state[lane] = read_le32(state_final_p + lane * 4);
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

        /* Update prev_q with the just-decoded symbol from i-1. */
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
        uint16_t T = *Tp;

        uint64_t x = state[lane];
        uint32_t slot = (uint32_t)(x % T);
        uint16_t sym = ttio_adaptive_inv_cum(cum, max_sym, slot);
        uint16_t f = count[sym];
        uint32_t c = cum[sym];

        x = (x / T) * (uint64_t)f + (uint64_t)slot - (uint64_t)c;

        while (x < TTIO_RANS_L) {
            if (lane_pos[lane] + 2u > lane_bytes[lane]) {
                free(slab);
                return TTIO_RANS_ERR_CORRUPT;
            }
            uint16_t chunk = read_le16(lane_data[lane] + lane_pos[lane]);
            x = (x << 16) | (uint64_t)chunk;
            lane_pos[lane] += 2u;
        }
        state[lane] = x;
        symbols[i] = (uint8_t)sym;
        prev_sym = (uint8_t)sym;

        ttio_adaptive_update_ctx(slab, ctx_dense, max_sym, sym);
    }

    /* Sanity: post-decode state must equal initial encoder state (L)
     * for each lane — encoder started at L and is reversible. */
    for (int lane = 0; lane < 4; lane++) {
        if (state[lane] != TTIO_RANS_L) {
            free(slab);
            return TTIO_RANS_ERR_CORRUPT;
        }
    }

    free(slab);
    return TTIO_RANS_OK;
}
