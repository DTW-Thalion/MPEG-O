/*
 * rans_encode_adaptive.c — adaptive M94.Z encoder.
 *
 * Per-symbol adaptive freq updates (CRAM 3.1 fqzcomp-Nx16). Encoder
 * walks the input forward, encoding each symbol with the current
 * (count, T) for its context, then updating per spec §3.3.
 *
 * 4-way interleaved rANS (lane = i mod 4). Encode is REVERSE order —
 * standard rANS pattern: pre-pass forward to build an op-list, then
 * encode last-to-first into the bitstream.
 *
 * Wire format per spec §5.2: substream_lengths (16 bytes) + 4 lane
 * byte streams + state_final (16 bytes). The header (magic + flags +
 * RLT + max_sym etc.) is built by the language wrapper, not here.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include "rans_adaptive_internal.h"
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

    /* Body layout: 16 (substream_lengths) + 4*lane_bytes + 16 (state_final).
     * For empty input, body = 16 + 16 = 32 bytes (4 zero lane lengths). */
    if (n_symbols == 0) {
        if (*out_len < 32) return TTIO_RANS_ERR_PARAM;
        memset(out, 0, 32);
        /* state_final = L for each lane (nothing encoded). */
        for (int lane = 0; lane < 4; lane++) {
            write_le32(out + 16 + lane * 4, TTIO_RANS_L);
        }
        *out_len = 32;
        return TTIO_RANS_OK;
    }

    /* Allocate one slab for forward-pass state evolution. */
    size_t slab_sz = ttio_adaptive_slab_size(n_contexts, max_sym);
    uint8_t *slab = (uint8_t *)malloc(slab_sz);
    if (!slab) return TTIO_RANS_ERR_ALLOC;
    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        ttio_adaptive_init_ctx(slab, ctx, max_sym);
    }

    /* PASS 1 (forward): record per-symbol (f, c, T) at the moment of
     * encoding, so PASS 2 (reverse) can replay encoder state without
     * re-running adaptive updates in reverse.
     *
     * Each entry is 8 bytes: u16 f, u16 c, u16 T, u16 reserved.
     * Total alloc: n_symbols * 8 bytes. For 100M symbols, 800 MB —
     * acceptable on dev hosts but tight. If this is a problem, swap
     * for an adaptive-state checkpoint scheme (every K symbols).
     */
    typedef struct enc_op { uint16_t f, c, T, _r; } enc_op_t;
    enc_op_t *ops = (enc_op_t *)malloc(n_symbols * sizeof(enc_op_t));
    if (!ops) { free(slab); return TTIO_RANS_ERR_ALLOC; }

    for (size_t i = 0; i < n_symbols; i++) {
        uint16_t ctx = contexts[i];
        uint16_t sym = (uint16_t)symbols[i];
        if (ctx >= n_contexts || sym >= max_sym) {
            free(ops); free(slab);
            return TTIO_RANS_ERR_PARAM;
        }
        const uint16_t *count = (const uint16_t *)(const void *)(slab
            + ttio_adaptive_count_offset(ctx, max_sym));
        const uint32_t *cum   = (const uint32_t *)(const void *)(slab
            + ttio_adaptive_cum_offset(ctx, max_sym));
        const uint16_t *Tp    = (const uint16_t *)(const void *)(slab
            + ttio_adaptive_T_offset(ctx, max_sym));
        ops[i].f = count[sym];
        ops[i].c = (uint16_t)cum[sym];
        ops[i].T = *Tp;
        ops[i]._r = 0;
        ttio_adaptive_update_ctx(slab, ctx, max_sym, sym);
    }
    free(slab);  /* not needed for pass 2 */

    /* PASS 2 (reverse): encode last-to-first into per-lane uint16
     * chunk buffers. */
    size_t pad = (4u - (n_symbols & 3u)) & 3u;
    size_t n_padded = n_symbols + pad;

    /* Per-lane chunk buffers — uint16[] sized to n_padded/4 + slack. */
    size_t init_cap = (n_padded / 4u) + 32u;
    uint16_t *buf[4];
    size_t len[4] = {0, 0, 0, 0};
    size_t cap[4] = {init_cap, init_cap, init_cap, init_cap};
    for (int lane = 0; lane < 4; lane++) {
        buf[lane] = (uint16_t *)malloc(cap[lane] * sizeof(uint16_t));
        if (!buf[lane]) {
            for (int j = 0; j < lane; j++) free(buf[j]);
            free(ops);
            return TTIO_RANS_ERR_ALLOC;
        }
    }

    uint64_t state[4] = { TTIO_RANS_L, TTIO_RANS_L, TTIO_RANS_L, TTIO_RANS_L };

    /* Encode reverse: i from n_symbols-1 down to 0. lane = i mod 4. */
    for (size_t i = n_symbols; i-- > 0; ) {
        int lane = (int)(i & 3u);
        uint16_t f = ops[i].f;
        uint16_t c = ops[i].c;
        uint16_t T = ops[i].T;
        uint64_t x = state[lane];
        /* x_max(s, T) = floor(M * f / T), M = b*L = 2^31. */
        uint64_t x_max = ((uint64_t)1u << 31) * (uint64_t)f / (uint64_t)T;
        /* Renormalise: pop while x >= x_max. */
        while (x >= x_max) {
            if (len[lane] >= cap[lane]) {
                cap[lane] *= 2;
                uint16_t *nbuf = (uint16_t *)realloc(buf[lane],
                    cap[lane] * sizeof(uint16_t));
                if (!nbuf) {
                    for (int j = 0; j < 4; j++) free(buf[j]);
                    free(ops);
                    return TTIO_RANS_ERR_ALLOC;
                }
                buf[lane] = nbuf;
            }
            buf[lane][len[lane]++] = (uint16_t)(x & 0xFFFFu);
            x >>= 16;
        }
        /* Encode step: x' = (x // f) * T + (x mod f) + c. */
        x = (x / f) * T + (x % f) + c;
        state[lane] = x;
    }

    /* Emit body: 16 bytes substream_lengths LE, then 4 streams in
     * REVERSED order (chunks were pushed LIFO; reverse to FIFO),
     * then 16 bytes state_final LE. */
    size_t lane_bytes_total = 0;
    for (int lane = 0; lane < 4; lane++) lane_bytes_total += len[lane] * 2u;
    size_t body_len = 16u + lane_bytes_total + 16u;
    if (*out_len < body_len) {
        for (int lane = 0; lane < 4; lane++) free(buf[lane]);
        free(ops);
        return TTIO_RANS_ERR_PARAM;
    }
    uint8_t *p = out;
    /* substream_lengths */
    for (int lane = 0; lane < 4; lane++) {
        write_le32(p + lane * 4, (uint32_t)(len[lane] * 2u));
    }
    p += 16;
    /* lane bytes (reverse chunk order, LE within chunk) */
    for (int lane = 0; lane < 4; lane++) {
        size_t n = len[lane];
        for (size_t j = 0; j < n; j++) {
            uint16_t chunk = buf[lane][n - 1u - j];
            *p++ = (uint8_t)chunk;
            *p++ = (uint8_t)(chunk >> 8);
        }
    }
    /* state_final */
    for (int lane = 0; lane < 4; lane++) {
        write_le32(p + lane * 4, (uint32_t)state[lane]);
    }

    *out_len = body_len;
    (void)n_padded;
    for (int lane = 0; lane < 4; lane++) free(buf[lane]);
    free(ops);
    return TTIO_RANS_OK;
}
