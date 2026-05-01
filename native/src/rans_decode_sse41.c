/*
 * rans_decode_sse41.c — SSE4.1-targeted rANS decode kernel.
 *
 * After Task 28 evaluation this kernel remains a thin delegate to the
 * scalar reference, compiled with -msse4.1 so gcc/clang can auto-
 * vectorise the 4-way interleaved hot loop.  See rans_decode_avx2.c
 * for the full rationale: hand-rolled __m128i intrinsics lost ~55%
 * throughput against the auto-vectorised scalar at -O3, and the
 * auto-vectorised baseline already exceeds the Task-28 throughput
 * target.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

int _ttio_rans_decode_block_sse41(
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
    return _ttio_rans_decode_block_scalar(
        compressed, comp_len, contexts, n_contexts,
        freq, cum, dtab, symbols, n_symbols);
}
