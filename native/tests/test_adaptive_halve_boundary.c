/*
 * test_adaptive_halve_boundary.c — verify halve operation at every
 * possible block boundary.
 *
 * STEP = 16, T_max = 65519. Halve fires when T + 16 > 65519, i.e.
 * T > 65503. Starting from T_init = max_sym = 256 and incrementing by
 * 16 each symbol, we hit the halve boundary at symbol index ~4080.
 * After halving, T resets to ~half of pre-halve, then grows again.
 * A 10000-symbol input crosses the halve boundary multiple times.
 *
 * This test runs encode/decode roundtrip on a 10000-symbol single-
 * context input (so all updates go to the same table — predictable
 * halve schedule). Decoder must mirror the halve at the same point.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    const uint16_t max_sym = 256;          /* worst case */
    const uint16_t n_contexts = 1;
    const uint16_t qbits = 12, pbits = 2, sloc = 14;
    const size_t n_symbols = 10000;
    const uint32_t read_len = (uint32_t)n_symbols;

    uint8_t *symbols = (uint8_t *)malloc(n_symbols);
    uint16_t *contexts = (uint16_t *)malloc(n_symbols * sizeof(uint16_t));
    if (!symbols || !contexts) return 1;

    /* Single-context, deterministic sequence cycling all 256 symbol
     * values — exercises every count[] slot. */
    for (size_t i = 0; i < n_symbols; i++) {
        symbols[i] = (uint8_t)(i & 0xFFu);
        contexts[i] = 0;
    }

    /* For decode-side parity we need the M94.Z context derivation to
     * always produce dense_ctx = 0. Force that by mapping every sparse
     * ctx to 0. */
    uint32_t ctx_cap = 1u << sloc;
    uint16_t *ctx_remap = (uint16_t *)malloc(ctx_cap * sizeof(uint16_t));
    if (!ctx_remap) return 1;
    for (uint32_t c = 0; c < ctx_cap; c++) ctx_remap[c] = 0;

    uint32_t read_lengths[1] = { read_len };
    uint8_t  revcomp[1]      = { 0 };

    /* Encode. */
    size_t out_cap = n_symbols * 4u + 64u;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) return 1;
    size_t out_len = out_cap;
    int rc = ttio_rans_encode_block_adaptive(
        symbols, contexts, n_symbols, n_contexts, max_sym, out, &out_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode rc=%d\n", rc);
        return 2;
    }

    /* Decode. */
    uint8_t *decoded = (uint8_t *)malloc(n_symbols);
    if (!decoded) return 1;
    ttio_m94z_params params = { .qbits = qbits, .pbits = pbits, .sloc = sloc };
    rc = ttio_rans_decode_block_adaptive_m94z(
        out, out_len, n_contexts, max_sym, &params, ctx_remap,
        read_lengths, 1, revcomp, /* pad */ 0, decoded, n_symbols);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "decode rc=%d\n", rc);
        return 3;
    }
    if (memcmp(decoded, symbols, n_symbols) != 0) {
        fprintf(stderr, "FAIL: roundtrip mismatch at halve boundary\n");
        for (size_t i = 0; i < n_symbols; i++) {
            if (decoded[i] != symbols[i]) {
                fprintf(stderr, "  first diff at i=%zu: got=%u want=%u\n",
                        i, decoded[i], symbols[i]);
                free(decoded); free(out); free(ctx_remap);
                free(contexts); free(symbols);
                return 4;
            }
        }
    }
    fprintf(stderr, "test_adaptive_halve_boundary: PASS (%zu symbols)\n",
            n_symbols);

    free(decoded); free(out); free(ctx_remap); free(contexts); free(symbols);
    return 0;
}
