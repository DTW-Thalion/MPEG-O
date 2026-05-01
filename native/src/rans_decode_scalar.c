/*
 * rans_decode_scalar.c — Scalar 4-way interleaved rANS decoder for TTI-O.
 *
 * Matches the byte layout produced by rans_encode_scalar.c:
 *   [0..15]   4 x uint32 LE  — final rANS states for lanes 0-3
 *   [16..31]  4 x uint32 LE  — per-lane data sizes in bytes
 *   [32..]    lane 0 data || lane 1 data || lane 2 data || lane 3 data
 *
 * The decoder walks forward (i from 0 to n_padded-1) with lane = i & 3,
 * reading 16-bit LE renormalisation chunks from each lane's sub-buffer.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include <string.h>

/* ── tiny helpers ──────────────────────────────────────────────────── */

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

/* ── public API ────────────────────────────────────────────────────── */

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols)
{
    /* ── 0. Validate ──────────────────────────────────────────────── */
    if (!compressed || !freq || !cum || !dtab || !symbols)
        return TTIO_RANS_ERR_PARAM;
    if (n_symbols == 0)
        return TTIO_RANS_OK;
    if (n_contexts == 0 || !contexts)
        return TTIO_RANS_ERR_PARAM;

    const size_t header_size = 32;
    if (comp_len < header_size)
        return TTIO_RANS_ERR_CORRUPT;

    /* ── 1. Read header ──────────────────────────────────────────── */
    uint32_t state[4];
    for (int lane = 0; lane < 4; lane++)
        state[lane] = read_le32(compressed + lane * 4);

    uint32_t lane_bytes[4];
    size_t total_data = 0;
    for (int lane = 0; lane < 4; lane++) {
        lane_bytes[lane] = read_le32(compressed + 16 + lane * 4);
        total_data += lane_bytes[lane];
    }

    if (comp_len < header_size + total_data)
        return TTIO_RANS_ERR_CORRUPT;

    /* Set up per-lane sub-buffer pointers and positions */
    const uint8_t *lane_data[4];
    size_t lane_pos[4];
    size_t offset = header_size;
    for (int lane = 0; lane < 4; lane++) {
        lane_data[lane] = compressed + offset;
        lane_pos[lane]  = 0;
        offset += lane_bytes[lane];
    }

    /* ── 2. Pad to multiple of 4 ────────────────────────────────── */
    size_t pad_count = (4 - (n_symbols & 3)) & 3;
    size_t n_padded  = n_symbols + pad_count;

    /* ── 3. Forward decode pass ──────────────────────────────────── */
    for (size_t i = 0; i < n_padded; i++) {
        int lane = (int)(i & 3);
        uint32_t x = state[lane];

        /* Determine context for this position */
        uint16_t ctx;
        if (i >= n_symbols) {
            ctx = 0; /* padding uses ctx=0, sym=0 */
        } else {
            ctx = contexts[i];
        }

        /* Decode step: slot = x & T_MASK */
        uint32_t slot = x & TTIO_RANS_T_MASK;
        uint8_t sym = dtab[ctx][slot];
        uint32_t f  = freq[ctx][sym];
        uint32_t c  = cum[ctx][sym];

        /* State update: x' = (x >> T_BITS) * f + slot - c */
        x = (x >> TTIO_RANS_T_BITS) * f + slot - c;

        /* Renormalise: read 16-bit chunks while x < L */
        while (x < TTIO_RANS_L) {
            if (lane_pos[lane] + 2 > lane_bytes[lane])
                return TTIO_RANS_ERR_CORRUPT;
            uint16_t chunk = read_le16(lane_data[lane] + lane_pos[lane]);
            x = (x << TTIO_RANS_B_BITS) | (uint32_t)chunk;
            lane_pos[lane] += 2;
        }

        state[lane] = x;

        /* Store decoded symbol (only for non-padding positions) */
        if (i < n_symbols)
            symbols[i] = sym;
    }

    return TTIO_RANS_OK;
}
