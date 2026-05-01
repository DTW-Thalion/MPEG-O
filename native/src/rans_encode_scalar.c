/*
 * rans_encode_scalar.c — Scalar 4-way interleaved rANS encoder for TTI-O.
 *
 * Byte layout of the encoded output:
 *   [0..15]   4 × uint32 LE  — final rANS states for lanes 0–3
 *   [16..31]  4 × uint32 LE  — per-lane data sizes in bytes
 *   [32..]    lane 0 data || lane 1 data || lane 2 data || lane 3 data
 *             Each lane's data is the reversed chunk list, stored as
 *             consecutive 16-bit LE values in decode-forward order.
 *
 * The encoder walks symbols in reverse (i from n_padded-1 down to 0),
 * with lane = i & 3.  Padding symbols (i >= n_symbols) use ctx=0, sym=0.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include <stdlib.h>
#include <string.h>

/* ── tiny helpers ──────────────────────────────────────────────────── */

static inline void write_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/* ── public API ────────────────────────────────────────────────────── */

int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len)
{
    /* ── 0. Validate ──────────────────────────────────────────────── */
    if (!out || !out_len)
        return TTIO_RANS_ERR_PARAM;
    if (n_symbols == 0) {
        /* Empty input: emit header of zeros */
        if (*out_len < 32)
            return TTIO_RANS_ERR_PARAM;
        memset(out, 0, 32);
        /* Final states = L, sizes = 0 */
        for (int lane = 0; lane < 4; lane++)
            write_le32(out + lane * 4, TTIO_RANS_L);
        for (int lane = 0; lane < 4; lane++)
            write_le32(out + 16 + lane * 4, 0);
        *out_len = 32;
        return TTIO_RANS_OK;
    }
    if (!symbols || !contexts || !freq || n_contexts == 0)
        return TTIO_RANS_ERR_PARAM;

    /* ── 1. Compute cumulative freqs ─────────────────────────────── */
    uint32_t (*cum)[256] = NULL;
    cum = (uint32_t (*)[256])calloc((size_t)n_contexts, 256 * sizeof(uint32_t));
    if (!cum)
        return TTIO_RANS_ERR_ALLOC;

    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) {
            cum[ctx][s] = running;
            running += freq[ctx][s];
        }
    }

    /* ── 2. Pad to multiple of 4 ─────────────────────────────────── */
    size_t pad_count = (4 - (n_symbols & 3)) & 3;
    size_t n_padded  = n_symbols + pad_count;

    /* Padding symbols use ctx=0, sym=0 — freq[0][0] must be non-zero */
    if (pad_count > 0 && freq[0][0] == 0) {
        free(cum);
        return TTIO_RANS_ERR_PARAM;
    }

    /* ── 3. Allocate per-lane chunk buffers ───────────────────────── */
    size_t cap_per_lane = (n_padded / 4 + 16) * 2 + 32;
    uint16_t *lane_chunks[4] = {NULL, NULL, NULL, NULL};
    size_t    lane_n[4]      = {0, 0, 0, 0};

    for (int lane = 0; lane < 4; lane++) {
        lane_chunks[lane] = (uint16_t *)malloc(cap_per_lane * sizeof(uint16_t));
        if (!lane_chunks[lane]) {
            for (int j = 0; j < lane; j++) free(lane_chunks[j]);
            free(cum);
            return TTIO_RANS_ERR_ALLOC;
        }
    }

    /* ── 4. Initialise states to L ───────────────────────────────── */
    uint32_t state[4];
    state[0] = TTIO_RANS_L;
    state[1] = TTIO_RANS_L;
    state[2] = TTIO_RANS_L;
    state[3] = TTIO_RANS_L;

    /* ── 5. Reverse encode pass ──────────────────────────────────── */
    for (size_t ii = n_padded; ii-- > 0; ) {
        int lane = (int)(ii & 3);
        uint16_t ctx;
        uint8_t  sym;

        if (ii >= n_symbols) {
            /* Padding symbol: ctx=0, sym=0 */
            ctx = 0;
            sym = 0;
        } else {
            ctx = contexts[ii];
            sym = symbols[ii];
        }

        uint32_t f = freq[ctx][sym];
        uint32_t c = cum[ctx][sym];
        uint32_t x = state[lane];
        uint32_t x_max = TTIO_RANS_X_MAX_PREFACTOR * f;

        /* Renormalise: emit low 16 bits while x >= x_max */
        while (x >= x_max) {
            lane_chunks[lane][lane_n[lane]] = (uint16_t)(x & TTIO_RANS_B_MASK);
            lane_n[lane]++;
            x >>= TTIO_RANS_B_BITS;
        }

        /* rANS encode step: x' = (x / f) * T + (x % f) + c */
        state[lane] = (x / f) * TTIO_RANS_T + (x % f) + c;
    }

    /* ── 6. Compute output size and pack ─────────────────────────── */
    size_t lane_bytes[4];
    size_t total_data = 0;
    for (int lane = 0; lane < 4; lane++) {
        lane_bytes[lane] = lane_n[lane] * 2;
        total_data += lane_bytes[lane];
    }

    size_t header_size = 32; /* 4*4 states + 4*4 lane sizes */
    size_t needed = header_size + total_data;
    if (*out_len < needed) {
        for (int lane = 0; lane < 4; lane++) free(lane_chunks[lane]);
        free(cum);
        *out_len = needed; /* Tell caller the required size */
        return TTIO_RANS_ERR_PARAM;
    }

    /* Write final states (4 × uint32 LE) */
    for (int lane = 0; lane < 4; lane++)
        write_le32(out + lane * 4, state[lane]);

    /* Write lane sizes (4 × uint32 LE) */
    for (int lane = 0; lane < 4; lane++)
        write_le32(out + 16 + lane * 4, (uint32_t)lane_bytes[lane]);

    /* Write lane data: chunks were appended in LIFO order during the
     * reverse pass, so we reverse them to produce decode-forward order.
     * Each chunk is a 16-bit LE value. */
    uint8_t *wp = out + header_size;
    for (int lane = 0; lane < 4; lane++) {
        size_t nc = lane_n[lane];
        for (size_t k = nc; k-- > 0; ) {
            uint16_t chunk = lane_chunks[lane][k];
            wp[0] = (uint8_t)(chunk & 0xFF);
            wp[1] = (uint8_t)((chunk >> 8) & 0xFF);
            wp += 2;
        }
    }

    *out_len = needed;

    for (int lane = 0; lane < 4; lane++) free(lane_chunks[lane]);
    free(cum);
    return TTIO_RANS_OK;
}
