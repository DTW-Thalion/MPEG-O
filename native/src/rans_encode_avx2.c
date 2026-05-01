/*
 * rans_encode_avx2.c — AVX2-targeted rANS encode kernel.
 *
 * For Phase B Task 12 this kernel delegates to the scalar reference
 * implementation but is compiled with -mavx2 so the auto-vectoriser
 * can lift hot loops to 256-bit registers where profitable.
 *
 * TODO(Task 18): hand-vectorise with <immintrin.h>:
 *   - VPGATHERDD (_mm256_i32gather_epi32) for freq/cum lookups
 *   - branchless renorm via _mm256_blendv_epi8
 *   - 8-wide state vector covering two consecutive 4-lane groups
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

int _ttio_rans_encode_block_avx2(
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
