/*
 * test_roundtrip.c — Round-trip tests for the scalar rANS encode/decode.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ── helpers ───────────────────────────────────────────────────────── */

/*
 * Build cumulative frequency table from freq table.
 * cum[ctx][sym] = sum of freq[ctx][0..sym-1].
 */
static void build_cum(uint16_t n_ctx,
                      const uint32_t (*freq)[256],
                      uint32_t (*cum)[256])
{
    for (uint16_t ctx = 0; ctx < n_ctx; ctx++) {
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) {
            cum[ctx][s] = running;
            running += freq[ctx][s];
        }
    }
}

/*
 * Round-trip helper: encode, then decode, then compare.
 * Returns 0 on success, non-zero on failure.
 */
static int roundtrip_check(const uint8_t  *symbols,
                           const uint16_t *contexts,
                           size_t          n,
                           uint16_t        n_ctx,
                           const uint32_t (*freq)[256])
{
    /* Build cumulative */
    uint32_t (*cum)[256] = (uint32_t (*)[256])calloc(n_ctx, 256 * sizeof(uint32_t));
    if (!cum) { fprintf(stderr, "alloc failed\n"); return 1; }
    build_cum(n_ctx, freq, cum);

    /* Build decode table */
    uint8_t (*dtab)[TTIO_RANS_T] = (uint8_t (*)[TTIO_RANS_T])calloc(n_ctx, TTIO_RANS_T);
    if (!dtab) { fprintf(stderr, "alloc failed\n"); free(cum); return 1; }
    ttio_rans_build_decode_table(n_ctx, freq,
                                 (const uint32_t (*)[256])cum, dtab);

    /* Encode */
    size_t enc_cap = 32 + n * 4 + 256; /* generous upper bound */
    uint8_t *enc_buf = (uint8_t *)malloc(enc_cap);
    if (!enc_buf) { fprintf(stderr, "alloc failed\n"); free(cum); free(dtab); return 1; }
    size_t enc_len = enc_cap;
    int rc = ttio_rans_encode_block(symbols, contexts, n, n_ctx,
                                    freq, enc_buf, &enc_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode failed: %d\n", rc);
        free(enc_buf); free(cum); free(dtab);
        return 1;
    }

    /* Decode */
    uint8_t *dec_buf = (uint8_t *)calloc(n, 1);
    if (!dec_buf) { fprintf(stderr, "alloc failed\n"); free(enc_buf); free(cum); free(dtab); return 1; }
    rc = ttio_rans_decode_block(enc_buf, enc_len, contexts, n_ctx,
                                freq,
                                (const uint32_t (*)[256])cum,
                                (const uint8_t (*)[TTIO_RANS_T])dtab,
                                dec_buf, n);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "decode failed: %d\n", rc);
        free(dec_buf); free(enc_buf); free(cum); free(dtab);
        return 1;
    }

    /* Compare */
    int mismatch = 0;
    for (size_t i = 0; i < n; i++) {
        if (dec_buf[i] != symbols[i]) {
            fprintf(stderr, "mismatch at %zu: expected %u, got %u\n",
                    i, symbols[i], dec_buf[i]);
            mismatch = 1;
            if (i > 8) break; /* limit output */
        }
    }

    free(dec_buf);
    free(enc_buf);
    free(cum);
    free(dtab);
    return mismatch;
}

/* ── test cases ────────────────────────────────────────────────────── */

static void test_simple_roundtrip(void)
{
    /* 8 symbols, 1 context, uniform freq across 4 symbols */
    uint8_t symbols[]  = {0, 1, 2, 3, 0, 1, 2, 3};
    uint16_t contexts[] = {0, 0, 0, 0, 0, 0, 0, 0};
    size_t n = 8;
    uint16_t n_ctx = 1;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][0] = 1024;
    freq[0][1] = 1024;
    freq[0][2] = 1024;
    freq[0][3] = 1024;

    int rc = roundtrip_check(symbols, contexts, n, n_ctx,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    printf("  test_simple_roundtrip: PASS\n");
}

static void test_non_uniform_freq(void)
{
    /* Skewed distribution: sym 0 is much more frequent */
    uint8_t symbols[]  = {0, 0, 0, 0, 0, 0, 1, 2};
    uint16_t contexts[] = {0, 0, 0, 0, 0, 0, 0, 0};
    size_t n = 8;
    uint16_t n_ctx = 1;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][0] = 3072;  /* 75% */
    freq[0][1] = 512;   /* 12.5% */
    freq[0][2] = 512;   /* 12.5% */
    /* Total = 4096 = T */

    int rc = roundtrip_check(symbols, contexts, n, n_ctx,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    printf("  test_non_uniform_freq: PASS\n");
}

static void test_single_symbol_repeated(void)
{
    /* All same symbol */
    size_t n = 32;
    uint8_t *symbols  = (uint8_t *)malloc(n);
    uint16_t *contexts = (uint16_t *)calloc(n, sizeof(uint16_t));
    assert(symbols && contexts);
    memset(symbols, 5, n);

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][5] = TTIO_RANS_T; /* sole symbol gets all probability */

    int rc = roundtrip_check(symbols, contexts, n, 1,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    free(symbols);
    free(contexts);
    printf("  test_single_symbol_repeated: PASS\n");
}

static void test_not_divisible_by_4(void)
{
    /* n=7: not divisible by 4 */
    uint8_t symbols[]   = {0, 1, 2, 3, 0, 1, 2};
    uint16_t contexts[] = {0, 0, 0, 0, 0, 0, 0};
    size_t n = 7;
    uint16_t n_ctx = 1;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][0] = 1024;
    freq[0][1] = 1024;
    freq[0][2] = 1024;
    freq[0][3] = 1024;

    int rc = roundtrip_check(symbols, contexts, n, n_ctx,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    printf("  test_not_divisible_by_4: PASS\n");
}

static void test_n_equals_1(void)
{
    /* Single symbol.  n=1 requires 3 padding symbols (ctx=0, sym=0),
     * so freq[0][0] must be non-zero. */
    uint8_t symbols[]   = {3};
    uint16_t contexts[] = {0};
    size_t n = 1;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][0] = 1;               /* needed for padding */
    freq[0][3] = TTIO_RANS_T - 1; /* 4095; total = 4096 */

    int rc = roundtrip_check(symbols, contexts, n, 1,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    printf("  test_n_equals_1: PASS\n");
}

static void test_n_equals_5(void)
{
    /* n=5: exercises padding of 3 */
    uint8_t symbols[]   = {0, 1, 2, 3, 0};
    uint16_t contexts[] = {0, 0, 0, 0, 0};
    size_t n = 5;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][0] = 1024;
    freq[0][1] = 1024;
    freq[0][2] = 1024;
    freq[0][3] = 1024;

    int rc = roundtrip_check(symbols, contexts, n, 1,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    printf("  test_n_equals_5: PASS\n");
}

static void test_large_input(void)
{
    /* 2000 symbols, 1 context, 8-symbol alphabet with varying freqs */
    size_t n = 2000;
    uint8_t *symbols  = (uint8_t *)malloc(n);
    uint16_t *contexts = (uint16_t *)calloc(n, sizeof(uint16_t));
    assert(symbols && contexts);

    /* Deterministic pseudo-random symbol generation */
    uint32_t rng = 12345;
    for (size_t i = 0; i < n; i++) {
        rng = rng * 1103515245 + 12345;
        symbols[i] = (uint8_t)((rng >> 16) & 7); /* 0-7 */
    }

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    /* Assign frequencies for symbols 0-7, summing to 4096 */
    freq[0][0] = 1024;
    freq[0][1] = 768;
    freq[0][2] = 640;
    freq[0][3] = 512;
    freq[0][4] = 384;
    freq[0][5] = 320;
    freq[0][6] = 256;
    freq[0][7] = 192;
    /* Total = 1024+768+640+512+384+320+256+192 = 4096 */

    int rc = roundtrip_check(symbols, contexts, n, 1,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    free(symbols);
    free(contexts);
    printf("  test_large_input: PASS\n");
}

static void test_multiple_contexts(void)
{
    /* 16 symbols, 2 contexts with different frequency distributions */
    size_t n = 16;
    uint8_t symbols[]   = {0, 1, 0, 1, 2, 3, 2, 3, 0, 0, 1, 1, 2, 2, 3, 3};
    uint16_t contexts[] = {0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1};
    uint16_t n_ctx = 2;

    uint32_t freq[2][256];
    memset(freq, 0, sizeof(freq));
    /* Context 0: symbols 0,1 only */
    freq[0][0] = 2048;
    freq[0][1] = 2048;
    /* Context 1: symbols 2,3 only */
    freq[1][2] = 2048;
    freq[1][3] = 2048;

    int rc = roundtrip_check(symbols, contexts, n, n_ctx,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    printf("  test_multiple_contexts: PASS\n");
}

static void test_large_multi_context(void)
{
    /* 1024 symbols, 4 contexts */
    size_t n = 1024;
    uint8_t *symbols  = (uint8_t *)malloc(n);
    uint16_t *contexts = (uint16_t *)malloc(n * sizeof(uint16_t));
    assert(symbols && contexts);

    uint32_t rng = 54321;
    for (size_t i = 0; i < n; i++) {
        rng = rng * 1103515245 + 12345;
        contexts[i] = (uint16_t)((rng >> 16) & 3); /* ctx 0-3 */
        rng = rng * 1103515245 + 12345;
        symbols[i] = (uint8_t)((rng >> 16) & 3); /* sym 0-3 */
    }

    uint32_t freq[4][256];
    memset(freq, 0, sizeof(freq));
    /* All 4 contexts use uniform distribution over {0,1,2,3} */
    for (int ctx = 0; ctx < 4; ctx++) {
        freq[ctx][0] = 1024;
        freq[ctx][1] = 1024;
        freq[ctx][2] = 1024;
        freq[ctx][3] = 1024;
    }

    int rc = roundtrip_check(symbols, contexts, n, 4,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    free(symbols);
    free(contexts);
    printf("  test_large_multi_context: PASS\n");
}

static void test_empty_input(void)
{
    /* n=0: empty input */
    uint8_t enc_buf[64];
    size_t enc_len = sizeof(enc_buf);

    int rc = ttio_rans_encode_block(NULL, NULL, 0, 0, NULL, enc_buf, &enc_len);
    assert(rc == TTIO_RANS_OK);
    assert(enc_len == 32);
    printf("  test_empty_input: PASS\n");
}

static void test_all_256_symbols(void)
{
    /* Use all 256 symbols, each with freq=16 (16*256=4096) */
    size_t n = 1024;
    uint8_t *symbols  = (uint8_t *)malloc(n);
    uint16_t *contexts = (uint16_t *)calloc(n, sizeof(uint16_t));
    assert(symbols && contexts);

    for (size_t i = 0; i < n; i++)
        symbols[i] = (uint8_t)(i & 0xFF);

    uint32_t freq[1][256];
    for (int s = 0; s < 256; s++)
        freq[0][s] = 16; /* uniform: 16 * 256 = 4096 */

    int rc = roundtrip_check(symbols, contexts, n, 1,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    free(symbols);
    free(contexts);
    printf("  test_all_256_symbols: PASS\n");
}

static void test_highly_skewed(void)
{
    /* One symbol dominates: sym 0 has freq 4081, sym 1..15 have freq 1 each */
    size_t n = 500;
    uint8_t *symbols  = (uint8_t *)malloc(n);
    uint16_t *contexts = (uint16_t *)calloc(n, sizeof(uint16_t));
    assert(symbols && contexts);

    /* Mostly 0 with rare other symbols */
    for (size_t i = 0; i < n; i++)
        symbols[i] = 0;
    symbols[100] = 1;
    symbols[200] = 2;
    symbols[300] = 3;
    symbols[400] = 4;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    freq[0][0] = 4091;
    freq[0][1] = 1;
    freq[0][2] = 1;
    freq[0][3] = 1;
    freq[0][4] = 1;
    /* Pad to total 4096 with sym 5 = 1 */
    freq[0][5] = 1;
    /* Total = 4091 + 5 = 4096 */

    int rc = roundtrip_check(symbols, contexts, n, 1,
                             (const uint32_t (*)[256])freq);
    assert(rc == 0);
    free(symbols);
    free(contexts);
    printf("  test_highly_skewed: PASS\n");
}

/* ── main ──────────────────────────────────────────────────────────── */

int main(void)
{
    printf("ttio_rans C tests:\n");

    test_empty_input();
    test_simple_roundtrip();
    test_non_uniform_freq();
    test_single_symbol_repeated();
    test_not_divisible_by_4();
    test_n_equals_1();
    test_n_equals_5();
    test_large_input();
    test_multiple_contexts();
    test_large_multi_context();
    test_all_256_symbols();
    test_highly_skewed();

    printf("All tests passed.\n");
    return 0;
}
