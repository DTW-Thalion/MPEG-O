/*
 * test_roundtrip.c -- Round-trip tests for the scalar rANS encode/decode.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static void build_cum(uint16_t n_ctx, const uint32_t (*freq)[256], uint32_t (*cum)[256])
{
    for (uint16_t ctx = 0; ctx < n_ctx; ctx++) {
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) { cum[ctx][s] = running; running += freq[ctx][s]; }
    }
}

static int roundtrip_check(const uint8_t *syms, const uint16_t *ctxs, size_t n,
                            uint16_t n_ctx, const uint32_t (*freq)[256])
{
    uint32_t (*cum)[256] = (uint32_t (*)[256])calloc(n_ctx, 256 * sizeof(uint32_t));
    if (!cum) return 1;
    build_cum(n_ctx, freq, cum);
    uint8_t (*dtab)[TTIO_RANS_T] = (uint8_t (*)[TTIO_RANS_T])calloc(n_ctx, TTIO_RANS_T);
    if (!dtab) { free(cum); return 1; }
    int brc = ttio_rans_build_decode_table(n_ctx, freq, (const uint32_t (*)[256])cum, dtab);
    if (brc != TTIO_RANS_OK) {
        fprintf(stderr, "build_decode_table failed: %d\n", brc);
        free(cum); free(dtab); return 1;
    }
    size_t enc_cap = 32 + n * 4 + 256;
    uint8_t *enc_buf = (uint8_t *)malloc(enc_cap);
    if (!enc_buf) { free(cum); free(dtab); return 1; }
    size_t enc_len = enc_cap;
    int rc = ttio_rans_encode_block(syms, ctxs, n, n_ctx, freq, enc_buf, &enc_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode failed: %d\n", rc);
        free(enc_buf); free(cum); free(dtab); return 1;
    }
    uint8_t *dec_buf = (uint8_t *)calloc(n, 1);
    if (!dec_buf) { free(enc_buf); free(cum); free(dtab); return 1; }
    rc = ttio_rans_decode_block(enc_buf, enc_len, ctxs, n_ctx, freq,
                                (const uint32_t (*)[256])cum,
                                (const uint8_t (*)[TTIO_RANS_T])dtab,
                                dec_buf, n);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "decode failed: %d\n", rc);
        free(dec_buf); free(enc_buf); free(cum); free(dtab); return 1;
    }
    int mismatch = 0;
    for (size_t i = 0; i < n; i++) {
        if (dec_buf[i] != syms[i]) {
            fprintf(stderr, "mismatch at %zu: expected %u got %u\n", i, syms[i], dec_buf[i]);
            mismatch = 1; break;
        }
    }
    free(dec_buf); free(enc_buf); free(cum); free(dtab);
    return mismatch;
}

/* round-trip tests */

static void test_empty_input(void) {
    uint8_t buf[64]; size_t len = sizeof(buf);
    assert(ttio_rans_encode_block(NULL, NULL, 0, 0, NULL, buf, &len) == TTIO_RANS_OK);
    assert(len == 32);
    printf("  test_empty_input: PASS\n");
}

static void test_simple_roundtrip(void) {
    uint8_t s[] = {0,1,2,3,0,1,2,3}; uint16_t c[] = {0,0,0,0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=1024; f[0][2]=1024; f[0][3]=1024;
    assert(roundtrip_check(s, c, 8, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_simple_roundtrip: PASS\n");
}

static void test_non_uniform_freq(void) {
    uint8_t s[] = {0,0,0,0,0,0,1,2}; uint16_t c[] = {0,0,0,0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=3072; f[0][1]=512; f[0][2]=512;
    assert(roundtrip_check(s, c, 8, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_non_uniform_freq: PASS\n");
}

static void test_single_symbol_repeated(void) {
    size_t n = 32; uint8_t *s = (uint8_t *)malloc(n); uint16_t *c = (uint16_t *)calloc(n, 2);
    assert(s && c); memset(s, 5, n);
    uint32_t f[1][256]; memset(f, 0, sizeof(f)); f[0][5] = TTIO_RANS_T;
    assert(roundtrip_check(s, c, n, 1, (const uint32_t (*)[256])f) == 0);
    free(s); free(c);
    printf("  test_single_symbol_repeated: PASS\n");
}

static void test_not_divisible_by_4(void) {
    /* n=7: pad=1 */
    uint8_t s[] = {0,1,2,3,0,1,2}; uint16_t c[] = {0,0,0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=1024; f[0][2]=1024; f[0][3]=1024;
    assert(roundtrip_check(s, c, 7, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_not_divisible_by_4: PASS\n");
}

static void test_n_equals_1(void) {
    /* n=1: pad=3 */
    uint8_t s[] = {3}; uint16_t c[] = {0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1; f[0][3]=TTIO_RANS_T-1;
    assert(roundtrip_check(s, c, 1, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_n_equals_1: PASS\n");
}

static void test_n_equals_5(void) {
    /* n=5: pad=3 */
    uint8_t s[] = {0,1,2,3,0}; uint16_t c[] = {0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=1024; f[0][2]=1024; f[0][3]=1024;
    assert(roundtrip_check(s, c, 5, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_n_equals_5: PASS\n");
}

static void test_n_equals_6(void) {
    /* n=6: pad=2 -- exercises pad_count==2 */
    uint8_t s[] = {0,1,2,3,0,1}; uint16_t c[] = {0,0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=1024; f[0][2]=1024; f[0][3]=1024;
    assert(roundtrip_check(s, c, 6, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_n_equals_6: PASS\n");
}

static void test_large_input(void) {
    size_t n = 2000; uint8_t *s = (uint8_t *)malloc(n); uint16_t *c = (uint16_t *)calloc(n, 2);
    assert(s && c);
    uint32_t rng = 12345;
    for (size_t i = 0; i < n; i++) { rng = rng*1103515245+12345; s[i] = (uint8_t)((rng>>16)&7); }
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=768; f[0][2]=640; f[0][3]=512;
    f[0][4]=384;  f[0][5]=320; f[0][6]=256; f[0][7]=192;
    assert(roundtrip_check(s, c, n, 1, (const uint32_t (*)[256])f) == 0);
    free(s); free(c);
    printf("  test_large_input: PASS\n");
}

static void test_multiple_contexts(void) {
    size_t n = 16;
    uint8_t s[]  = {0,1,0,1,2,3,2,3,0,0,1,1,2,2,3,3};
    uint16_t c[] = {0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,1};
    uint32_t f[2][256]; memset(f, 0, sizeof(f));
    f[0][0]=2048; f[0][1]=2048; f[1][2]=2048; f[1][3]=2048;
    assert(roundtrip_check(s, c, n, 2, (const uint32_t (*)[256])f) == 0);
    printf("  test_multiple_contexts: PASS\n");
}

static void test_large_multi_context(void) {
    size_t n = 1024; uint8_t *s = (uint8_t *)malloc(n); uint16_t *c = (uint16_t *)malloc(n*2);
    assert(s && c);
    uint32_t rng = 54321;
    for (size_t i = 0; i < n; i++) {
        rng=rng*1103515245+12345; c[i]=(uint16_t)((rng>>16)&3);
        rng=rng*1103515245+12345; s[i]=(uint8_t)((rng>>16)&3);
    }
    uint32_t f[4][256]; memset(f, 0, sizeof(f));
    for (int ctx=0; ctx<4; ctx++) { f[ctx][0]=1024; f[ctx][1]=1024; f[ctx][2]=1024; f[ctx][3]=1024; }
    assert(roundtrip_check(s, c, n, 4, (const uint32_t (*)[256])f) == 0);
    free(s); free(c);
    printf("  test_large_multi_context: PASS\n");
}

static void test_all_256_symbols(void) {
    size_t n = 1024; uint8_t *s = (uint8_t *)malloc(n); uint16_t *c = (uint16_t *)calloc(n, 2);
    assert(s && c);
    for (size_t i = 0; i < n; i++) s[i] = (uint8_t)(i & 0xFF);
    uint32_t f[1][256]; for (int sym = 0; sym < 256; sym++) f[0][sym] = 16;
    assert(roundtrip_check(s, c, n, 1, (const uint32_t (*)[256])f) == 0);
    free(s); free(c);
    printf("  test_all_256_symbols: PASS\n");
}

static void test_highly_skewed(void) {
    size_t n = 500; uint8_t *s = (uint8_t *)malloc(n); uint16_t *c = (uint16_t *)calloc(n, 2);
    assert(s && c);
    for (size_t i = 0; i < n; i++) s[i] = 0;
    s[100]=1; s[200]=2; s[300]=3; s[400]=4;
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=4091; f[0][1]=1; f[0][2]=1; f[0][3]=1; f[0][4]=1; f[0][5]=1;
    assert(roundtrip_check(s, c, n, 1, (const uint32_t (*)[256])f) == 0);
    free(s); free(c);
    printf("  test_highly_skewed: PASS\n");
}

/* error-path tests */

static void test_err_zero_freq_encode(void) {
    /* Symbol 1 has freq=0: encoder must reject with TTIO_RANS_ERR_PARAM */
    uint8_t s[] = {0,1,2,3}; uint16_t c[] = {0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=2048; /* f[0][1] stays 0 */ f[0][2]=1024; f[0][3]=1024;
    uint8_t buf[1024]; size_t len = sizeof(buf);
    assert(ttio_rans_encode_block(s, c, 4, 1, (const uint32_t (*)[256])f, buf, &len) == TTIO_RANS_ERR_PARAM);
    printf("  test_err_zero_freq_encode: PASS\n");
}

static void test_err_ctx_out_of_range_encode(void) {
    /* contexts[1]=5 but n_contexts=2: encoder must reject */
    uint8_t s[] = {0,1,2,3}; uint16_t c[] = {0,5,0,0};
    uint32_t f[2][256]; memset(f, 0, sizeof(f));
    f[0][0]=2048; f[0][1]=2048; f[1][0]=2048; f[1][1]=2048;
    uint8_t buf[1024]; size_t len = sizeof(buf);
    assert(ttio_rans_encode_block(s, c, 4, 2, (const uint32_t (*)[256])f, buf, &len) == TTIO_RANS_ERR_PARAM);
    printf("  test_err_ctx_out_of_range_encode: PASS\n");
}

static void test_err_ctx_out_of_range_decode(void) {
    /* Encode with valid contexts, then decode with out-of-range context */
    uint8_t s[] = {0,1,0,1}; uint16_t c_enc[] = {0,0,0,0}; uint16_t c_bad[] = {0,5,0,0};
    uint32_t f[2][256]; memset(f, 0, sizeof(f));
    f[0][0]=2048; f[0][1]=2048; f[1][0]=2048; f[1][1]=2048;
    uint32_t cum[2][256];
    for (int ctx=0; ctx<2; ctx++) {
        uint32_t r=0;
        for (int sym=0; sym<256; sym++) { cum[ctx][sym]=r; r+=f[ctx][sym]; }
    }
    uint8_t dtab[2][TTIO_RANS_T];
    assert(ttio_rans_build_decode_table(2, (const uint32_t (*)[256])f,
                                        (const uint32_t (*)[256])cum, dtab) == TTIO_RANS_OK);
    uint8_t enc[1024]; size_t enc_len = sizeof(enc);
    assert(ttio_rans_encode_block(s, c_enc, 4, 2, (const uint32_t (*)[256])f, enc, &enc_len) == TTIO_RANS_OK);
    uint8_t dec[4];
    int rc = ttio_rans_decode_block(enc, enc_len, c_bad, 2,
                                    (const uint32_t (*)[256])f,
                                    (const uint32_t (*)[256])cum,
                                    (const uint8_t (*)[TTIO_RANS_T])dtab,
                                    dec, 4);
    assert(rc == TTIO_RANS_ERR_PARAM);
    printf("  test_err_ctx_out_of_range_decode: PASS\n");
}

static void test_err_build_decode_table_overflow(void) {
    /* sum(freq) = T+1: must return ERR_PARAM */
    uint32_t f[1][256]; uint32_t cum[1][256]; uint8_t dtab[1][TTIO_RANS_T];
    memset(f, 0, sizeof(f)); memset(cum, 0, sizeof(cum));
    f[0][0] = TTIO_RANS_T/2 + 1;   /* 2049 */
    f[0][1] = TTIO_RANS_T/2;       /* 2048; total = 4097 > T */
    cum[0][0] = 0; cum[0][1] = f[0][0];
    assert(ttio_rans_build_decode_table(1, (const uint32_t (*)[256])f,
                                        (const uint32_t (*)[256])cum, dtab) == TTIO_RANS_ERR_PARAM);
    printf("  test_err_build_decode_table_overflow: PASS\n");
}

/* main */

int main(void)
{
    printf("ttio_rans C tests:\n");

    /* Round-trip tests */
    test_empty_input();
    test_simple_roundtrip();
    test_non_uniform_freq();
    test_single_symbol_repeated();
    test_not_divisible_by_4();
    test_n_equals_1();
    test_n_equals_5();
    test_n_equals_6();
    test_large_input();
    test_multiple_contexts();
    test_large_multi_context();
    test_all_256_symbols();
    test_highly_skewed();

    /* Error-path tests */
    test_err_zero_freq_encode();
    test_err_ctx_out_of_range_encode();
    test_err_ctx_out_of_range_decode();
    test_err_build_decode_table_overflow();

    printf("All tests passed.\n");
    return 0;
}
