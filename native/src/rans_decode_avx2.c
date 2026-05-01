/*
 * rans_decode_avx2.c — AVX2-targeted rANS decode kernel.
 *
 * For Phase B Task 12 this kernel delegates to the scalar reference
 * implementation but is compiled with -mavx2 so the auto-vectoriser
 * can lift hot loops to 256-bit registers where profitable.
 *
 * TODO(Task 18): hand-vectorise with <immintrin.h>:
 *   - VPGATHERDD (_mm256_i32gather_epi32) for freq/cum lookups
 *   - branchless renorm via _mm256_blendv_epi8
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

int _ttio_rans_decode_block_avx2(
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
