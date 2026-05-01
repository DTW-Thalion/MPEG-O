/*
 * rans_encode_sse41.c — SSE4.1-targeted rANS encode kernel.
 *
 * For Phase B Task 12 this kernel delegates to the scalar reference
 * implementation but is compiled with -msse4.1 so the auto-vectoriser
 * can lift the per-lane state read/write and renormalisation loop.
 *
 * TODO(Task 18): hand-vectorise hot path with <smmintrin.h> intrinsics
 *   - parallel renormalisation comparisons via _mm_cmpgt_epi32
 *   - parallel state read/write via _mm_load/store_si128
 *   - per-lane freq/cum lookups remain scalar (no gather in SSE4.1)
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

int _ttio_rans_encode_block_sse41(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len)
{
    return _ttio_rans_encode_block_scalar(
        symbols, contexts, n_symbols, n_contexts, freq, out, out_len);
}
