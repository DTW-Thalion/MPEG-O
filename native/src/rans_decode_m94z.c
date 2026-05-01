/*
 * rans_decode_m94z.c — Native M94.Z decode with inline context derivation.
 *
 * The streaming decoder (rans_decode_streaming.c) uses a caller-supplied
 * resolver callback so the front-end binding (Python/Java/ObjC) can plug
 * in any context model.  For the specific M94.Z codec this round-trips
 * out of native code per symbol, which on a hot 10-million-symbol decode
 * costs more than the pure-language scalar path (Task 26b/26c finding).
 *
 * This entry point bakes the M94.Z context formula directly into C so
 * the decode loop never leaves native code.  Mirrors the Python
 * (`fqzcomp_nx16_z.py`) and Java (`FqzcompNx16Z.java`) context derivation
 * byte-for-byte — both languages already include cross-language fixture
 * tests guarding parity, and any drift here will be caught by those.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"
#include <string.h>

/* ── tiny helpers (duplicated from rans_decode_scalar.c) ────────────── */

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

/* ── M94.Z context formula (matches python/java/objc references) ──── */

static inline uint32_t m94z_position_bucket(
    uint32_t position, uint32_t read_length, uint32_t pbits)
{
    if (pbits == 0) return 0;
    uint32_t n_buckets = 1u << pbits;
    if (read_length == 0 || position == 0) return 0;
    if (position >= read_length) return n_buckets - 1u;
    /* Use 64-bit product to avoid overflow on long reads × small pbits. */
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

/* ── public entry point ───────────────────────────────────────────── */

int ttio_rans_decode_block_m94z(
    const uint8_t            *compressed,
    size_t                    comp_len,
    uint16_t                  n_contexts,
    const uint32_t          (*freq)[256],
    const uint32_t          (*cum)[256],
    const uint8_t           (*dtab)[TTIO_RANS_T],
    const ttio_m94z_params   *params,
    const uint16_t           *ctx_remap,
    const uint32_t           *read_lengths,
    size_t                    n_reads,
    const uint8_t            *revcomp_flags,
    uint16_t                  pad_ctx_dense,
    uint8_t                  *symbols,
    size_t                    n_symbols)
{
    /* ── 0. Validate ────────────────────────────────────────────────── */
    if (!compressed || !freq || !cum || !dtab || !symbols || !params)
        return TTIO_RANS_ERR_PARAM;
    if (n_symbols == 0)
        return TTIO_RANS_OK;
    if (n_contexts == 0 || pad_ctx_dense >= n_contexts)
        return TTIO_RANS_ERR_PARAM;
    if (n_reads > 0 && (!read_lengths || !revcomp_flags))
        return TTIO_RANS_ERR_PARAM;
    /* sloc must be at most 16 because contexts[] downstream is uint16
     * and we mask against 1<<sloc. qbits/pbits sanity: qbits+pbits+1
     * must be packable in 32 bits. */
    if (params->sloc == 0 || params->sloc > 16)
        return TTIO_RANS_ERR_PARAM;
    if (params->qbits == 0 || params->qbits > 24)
        return TTIO_RANS_ERR_PARAM;
    if (params->pbits > 8)
        return TTIO_RANS_ERR_PARAM;

    const size_t header_size = 32;
    if (comp_len < header_size)
        return TTIO_RANS_ERR_CORRUPT;

    /* ── 1. Read header ─────────────────────────────────────────────── */
    uint32_t state[TTIO_RANS_STREAMS];
    for (int lane = 0; lane < TTIO_RANS_STREAMS; lane++)
        state[lane] = read_le32(compressed + lane * 4);

    uint32_t lane_bytes[TTIO_RANS_STREAMS];
    size_t total_data = 0;
    for (int lane = 0; lane < TTIO_RANS_STREAMS; lane++) {
        lane_bytes[lane] = read_le32(compressed + 16 + lane * 4);
        total_data += lane_bytes[lane];
    }
    if (comp_len < header_size + total_data)
        return TTIO_RANS_ERR_CORRUPT;

    const uint8_t *lane_data[TTIO_RANS_STREAMS];
    size_t lane_pos[TTIO_RANS_STREAMS];
    size_t offset = header_size;
    for (int lane = 0; lane < TTIO_RANS_STREAMS; lane++) {
        lane_data[lane] = compressed + offset;
        lane_pos[lane]  = 0;
        offset += lane_bytes[lane];
    }

    /* ── 2. Pad to multiple of TTIO_RANS_STREAMS ───────────────────── */
    if (n_symbols > (size_t)0 - 3)
        return TTIO_RANS_ERR_PARAM;
    size_t pad_count = (TTIO_RANS_STREAMS
                       - (n_symbols & (TTIO_RANS_STREAMS - 1)))
                      & (TTIO_RANS_STREAMS - 1);
    size_t n_padded = n_symbols + pad_count;

    /* ── 3. Sanity-check that read_lengths sums to n_symbols ────────── */
    if (n_reads > 0) {
        uint64_t sum = 0;
        for (size_t r = 0; r < n_reads; r++) sum += read_lengths[r];
        if (sum != n_symbols)
            return TTIO_RANS_ERR_PARAM;
    }

    /* ── 4. M94.Z context-derivation state ──────────────────────────── */
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

    /* ── 5. Forward decode pass ─────────────────────────────────────── */
    for (size_t i = 0; i < n_padded; i++) {
        int lane = (int)(i & (TTIO_RANS_STREAMS - 1));
        uint32_t x = state[lane];

        /* Determine context for position i. */
        uint16_t ctx;
        if (i >= n_symbols) {
            ctx = pad_ctx_dense;
        } else {
            /* Update prev_q ring with the just-decoded symbol from i-1.
             * Mirror Python/Java exactly: this happens BEFORE we check
             * the read boundary, but the boundary reset zeroes prev_q
             * anyway, so the order only matters within a read. */
            if (i > 0) {
                prev_q = ((prev_q << shift)
                          | ((uint32_t)prev_sym & shift_mask)) & qmask_local;
                pos_in_read += 1u;
            }

            /* Read boundary: when we cross cumulative_read_end and there
             * are more reads, advance to the next read and reset state. */
            if (i > 0 && i >= cumulative_read_end
                && read_idx + 1 < n_reads) {
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
            if (ctx_remap) {
                /* The sparse→dense map is sized 1<<sloc.  Any sparse ctx
                 * that wasn't in the active set should map to
                 * pad_ctx_dense — but mapping is the caller's job to
                 * fill (typically with 0xFFFF for "missing" and we then
                 * substitute pad_ctx_dense here). Here we accept any
                 * 0..n_contexts-1 directly. */
                uint16_t mapped = ctx_remap[ctx_sparse];
                ctx = (mapped < n_contexts) ? mapped : pad_ctx_dense;
            } else {
                ctx = (uint16_t)((ctx_sparse < n_contexts)
                                 ? ctx_sparse : pad_ctx_dense);
            }
        }

        /* ── rANS scalar decode step (matches rans_decode_scalar.c) ── */
        uint32_t slot = x & TTIO_RANS_T_MASK;
        uint8_t  sym  = dtab[ctx][slot];
        uint32_t f    = freq[ctx][sym];
        uint32_t c    = cum[ctx][sym];

        x = (x >> TTIO_RANS_T_BITS) * f + slot - c;

        while (x < TTIO_RANS_L) {
            if (lane_pos[lane] + 2 > lane_bytes[lane])
                return TTIO_RANS_ERR_CORRUPT;
            uint16_t chunk = read_le16(lane_data[lane] + lane_pos[lane]);
            x = (x << TTIO_RANS_B_BITS) | (uint32_t)chunk;
            lane_pos[lane] += 2;
        }

        state[lane] = x;

        if (i < n_symbols) {
            symbols[i] = sym;
            prev_sym = sym;
        }
    }

    return TTIO_RANS_OK;
}
