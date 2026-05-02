/*
 * rans_adaptive_internal.h — shared helpers for the adaptive kernels.
 *
 * These are used by both rans_encode_adaptive.c and
 * rans_decode_adaptive.c. The struct layout and update rules MUST be
 * identical on both sides (lockstep adaptive symmetry, see spec §2.4).
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#ifndef TTIO_RANS_ADAPTIVE_INTERNAL_H
#define TTIO_RANS_ADAPTIVE_INTERNAL_H

#include "ttio_rans.h"
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/*
 * Per-context adaptive table.
 * count[s]:  uint16 symbol counts (range [0, T_max])
 * cum[s]:    uint32 cumulative — cum[0] = 0, cum[max_sym] = T
 * T:         current total of count[0..max_sym)
 *
 * Allocated as one flat slab per encode/decode call:
 *   slab = malloc(n_contexts * (max_sym * 6 + 4) bytes)
 * Indexed via the helpers below.
 */

/* Per-ctx slot size: count[max_sym] u16 + cum[max_sym+1] u32 + T u16. */
static inline size_t ttio_adaptive_slot_size(uint16_t max_sym)
{
    return (size_t)((max_sym * 2u) + ((max_sym + 1u) * 4u) + 2u);
}

static inline size_t ttio_adaptive_count_offset(uint16_t ctx, uint16_t max_sym)
{
    return (size_t)ctx * ttio_adaptive_slot_size(max_sym);
}

static inline size_t ttio_adaptive_cum_offset(uint16_t ctx, uint16_t max_sym)
{
    return ttio_adaptive_count_offset(ctx, max_sym) + (size_t)max_sym * 2u;
}

static inline size_t ttio_adaptive_T_offset(uint16_t ctx, uint16_t max_sym)
{
    return ttio_adaptive_cum_offset(ctx, max_sym) + (size_t)(max_sym + 1u) * 4u;
}

static inline size_t ttio_adaptive_slab_size(uint16_t n_contexts, uint16_t max_sym)
{
    return (size_t)n_contexts * ttio_adaptive_slot_size(max_sym);
}

/*
 * Initialise a context's count/cum/T:
 *   count[s] = 1 for s ∈ [0, max_sym)
 *   cum[s]   = s for s ∈ [0, max_sym]
 *   T        = max_sym
 */
static inline void ttio_adaptive_init_ctx(uint8_t *slab, uint16_t ctx,
                                          uint16_t max_sym)
{
    uint16_t *count = (uint16_t *)(void *)(slab + ttio_adaptive_count_offset(ctx, max_sym));
    uint32_t *cum   = (uint32_t *)(void *)(slab + ttio_adaptive_cum_offset  (ctx, max_sym));
    uint16_t *T     = (uint16_t *)(void *)(slab + ttio_adaptive_T_offset    (ctx, max_sym));
    for (uint16_t s = 0; s < max_sym; s++) {
        count[s] = 1u;
        cum[s] = s;
    }
    cum[max_sym] = max_sym;
    *T = max_sym;
}

/*
 * Halve all counts in a context's table:
 *   count[s] = count[s] - (count[s] >> 1)   == ceil(count[s] / 2)
 * After halving, recompute cum[] and T from scratch.
 */
static inline void ttio_adaptive_halve_ctx(uint8_t *slab, uint16_t ctx,
                                           uint16_t max_sym)
{
    uint16_t *count = (uint16_t *)(void *)(slab + ttio_adaptive_count_offset(ctx, max_sym));
    uint32_t *cum   = (uint32_t *)(void *)(slab + ttio_adaptive_cum_offset  (ctx, max_sym));
    uint16_t *T     = (uint16_t *)(void *)(slab + ttio_adaptive_T_offset    (ctx, max_sym));
    uint32_t running = 0u;
    for (uint16_t s = 0; s < max_sym; s++) {
        count[s] = (uint16_t)(count[s] - (count[s] >> 1));  /* ceil(count[s] / 2) */
        cum[s] = running;
        running += count[s];
    }
    cum[max_sym] = running;
    *T = (uint16_t)running;
}

/*
 * Update a context after encoding/decoding symbol sym:
 *   count[sym] += STEP, T += STEP, cum[s] += STEP for s > sym.
 * Then check halve trigger and halve if needed.
 */
static inline void ttio_adaptive_update_ctx(uint8_t *slab, uint16_t ctx,
                                            uint16_t max_sym, uint16_t sym)
{
    uint16_t *count = (uint16_t *)(void *)(slab + ttio_adaptive_count_offset(ctx, max_sym));
    uint32_t *cum   = (uint32_t *)(void *)(slab + ttio_adaptive_cum_offset  (ctx, max_sym));
    uint16_t *T     = (uint16_t *)(void *)(slab + ttio_adaptive_T_offset    (ctx, max_sym));

    count[sym] = (uint16_t)(count[sym] + TTIO_RANS_ADAPTIVE_STEP);
    for (uint16_t s = (uint16_t)(sym + 1); s <= max_sym; s++) {
        cum[s] += TTIO_RANS_ADAPTIVE_STEP;
    }
    *T = (uint16_t)(*T + TTIO_RANS_ADAPTIVE_STEP);

    /* Halve check before next symbol. */
    if ((uint32_t)*T + TTIO_RANS_ADAPTIVE_STEP > TTIO_RANS_ADAPTIVE_T_MAX) {
        ttio_adaptive_halve_ctx(slab, ctx, max_sym);
    }
}

/*
 * Lookup helper: given a slot value in [0, T), find the symbol s
 * such that cum[s] <= slot < cum[s+1]. Linear scan; O(max_sym).
 *
 * Acceptable because max_sym ≤ 256 and the linear scan is well-
 * predicted on monotonic data (qualities cluster around bin centres).
 * If profiling shows this is hot, switch to binary search.
 */
static inline uint16_t ttio_adaptive_inv_cum(const uint32_t *cum,
                                             uint16_t max_sym, uint32_t slot)
{
    for (uint16_t s = 0; s < max_sym; s++) {
        if (cum[s + 1] > slot) {
            return s;
        }
    }
    /* Should be unreachable for slot < T = cum[max_sym]. */
    return (uint16_t)(max_sym - 1u);
}

#endif /* TTIO_RANS_ADAPTIVE_INTERNAL_H */
