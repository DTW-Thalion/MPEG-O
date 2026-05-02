/*
 * test_adaptive_max_sym_bounds.c — boundary tests for max_sym.
 *
 * Tests max_sym ∈ {1, 2, 41, 94, 256} on small fixed-size inputs.
 * Verifies encode/decode roundtrip for each.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int test_one(uint16_t max_sym)
{
    const uint16_t n_contexts = 1;
    const uint16_t qbits = 12, pbits = 2, sloc = 14;
    const size_t n_symbols = 200;
    const uint32_t read_len = (uint32_t)n_symbols;

    uint8_t *symbols = (uint8_t *)malloc(n_symbols);
    uint16_t *contexts = (uint16_t *)malloc(n_symbols * sizeof(uint16_t));
    if (!symbols || !contexts) return 1;

    /* Sequential symbols modulo max_sym, all in single context. */
    for (size_t i = 0; i < n_symbols; i++) {
        symbols[i] = (uint8_t)(i % max_sym);
        contexts[i] = 0;
    }

    uint32_t ctx_cap = 1u << sloc;
    uint16_t *ctx_remap = (uint16_t *)malloc(ctx_cap * sizeof(uint16_t));
    if (!ctx_remap) return 1;
    for (uint32_t c = 0; c < ctx_cap; c++) ctx_remap[c] = 0;

    uint32_t read_lengths[1] = { read_len };
    uint8_t  revcomp[1]      = { 0 };

    size_t out_cap = n_symbols * 4u + 64u;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) return 1;
    size_t out_len = out_cap;
    int rc = ttio_rans_encode_block_adaptive(
        symbols, contexts, n_symbols, n_contexts, max_sym, out, &out_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "max_sym=%u encode rc=%d\n", max_sym, rc);
        return 2;
    }

    uint8_t *decoded = (uint8_t *)malloc(n_symbols);
    if (!decoded) return 1;
    ttio_m94z_params params = { .qbits = qbits, .pbits = pbits, .sloc = sloc };
    rc = ttio_rans_decode_block_adaptive_m94z(
        out, out_len, n_contexts, max_sym, &params, ctx_remap,
        read_lengths, 1, revcomp, /* pad */ 0, decoded, n_symbols);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "max_sym=%u decode rc=%d\n", max_sym, rc);
        return 3;
    }
    if (memcmp(decoded, symbols, n_symbols) != 0) {
        fprintf(stderr, "max_sym=%u: roundtrip mismatch\n", max_sym);
        return 4;
    }
    fprintf(stderr, "  max_sym=%u: PASS\n", max_sym);
    free(decoded); free(out); free(ctx_remap); free(contexts); free(symbols);
    return 0;
}

int main(void)
{
    uint16_t bounds[] = { 1u, 2u, 41u, 94u, 256u };
    for (size_t i = 0; i < sizeof(bounds) / sizeof(bounds[0]); i++) {
        int rc = test_one(bounds[i]);
        if (rc != 0) {
            fprintf(stderr, "test_adaptive_max_sym_bounds: FAILED at max_sym=%u rc=%d\n",
                    bounds[i], rc);
            return 1;
        }
    }
    fprintf(stderr, "test_adaptive_max_sym_bounds: PASS\n");
    return 0;
}
