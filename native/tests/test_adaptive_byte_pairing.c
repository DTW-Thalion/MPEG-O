/*
 * test_adaptive_byte_pairing.c — fuzz test for adaptive byte-pairing.
 *
 * Generates 200 random (symbols, contexts, max_sym) inputs of varying
 * sizes, runs each through the encoder, asserts encode succeeds and
 * produces a non-trivial output. This is the empirical complement to
 * the spec §2 byte-pairing proof — any boundary issue in the encoder
 * surfaces here.
 *
 * Roundtrip-with-decode is left out because the decoder uses inline
 * M94.Z context derivation, not the random contexts the fuzz generates;
 * a static-context decode variant is out of scope for L2.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rng_state = 0xCAFEBABEDEADBEEFULL;

static uint64_t rng_next(void)
{
    rng_state = rng_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return rng_state;
}

static int run_one(size_t n_symbols, uint16_t max_sym, uint16_t n_contexts)
{
    uint8_t *symbols = (uint8_t *)malloc(n_symbols ? n_symbols : 1);
    uint16_t *contexts = (uint16_t *)malloc((n_symbols ? n_symbols : 1) * sizeof(uint16_t));
    if (!symbols || !contexts) { free(symbols); free(contexts); return 1; }

    for (size_t i = 0; i < n_symbols; i++) {
        symbols[i] = (uint8_t)(rng_next() % max_sym);
        contexts[i] = (uint16_t)(rng_next() % n_contexts);
    }

    /* Encode. */
    size_t out_cap = n_symbols * 4u + 256u;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) { free(symbols); free(contexts); return 1; }
    size_t out_len = out_cap;
    int rc = ttio_rans_encode_block_adaptive(
        symbols, contexts, n_symbols, n_contexts, max_sym,
        out, &out_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode rc=%d (n=%zu max_sym=%u n_ctx=%u)\n",
                rc, n_symbols, max_sym, n_contexts);
        free(out); free(symbols); free(contexts);
        return 2;
    }

    /* Sanity: non-empty input must produce more than the 32-byte
     * header-only body. */
    if (n_symbols > 0 && out_len <= 32) {
        fprintf(stderr, "encode produced suspiciously small output (n=%zu, out=%zu)\n",
                n_symbols, out_len);
        free(out); free(symbols); free(contexts);
        return 3;
    }

    free(out); free(symbols); free(contexts);
    return 0;
}

int main(void)
{
    int failures = 0;
    /* Fuzz: 200 trials with varying parameters. */
    for (int trial = 0; trial < 200; trial++) {
        size_t n = 1u + (rng_next() % 5000u);  /* 1..5000 */
        uint16_t max_sym = (uint16_t)(1u + (rng_next() % 256u));  /* 1..256 */
        uint16_t n_ctx   = (uint16_t)(1u + (rng_next() % 1000u)); /* 1..1000 */
        int rc = run_one(n, max_sym, n_ctx);
        if (rc != 0) {
            fprintf(stderr, "trial %d FAILED rc=%d n=%zu max_sym=%u n_ctx=%u\n",
                    trial, rc, n, max_sym, n_ctx);
            failures++;
            if (failures > 5) break;
        }
    }
    if (failures > 0) {
        fprintf(stderr, "test_adaptive_byte_pairing: %d/200 FAILED\n", failures);
        return 1;
    }
    fprintf(stderr, "test_adaptive_byte_pairing: PASS (200 trials)\n");
    return 0;
}
