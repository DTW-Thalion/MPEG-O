/*
 * test_streaming.c -- Tests for the streaming/callback rANS decoder.
 *
 * The streaming decoder must produce byte-identical output to the
 * regular ttio_rans_decode_block when the resolver simply returns
 * contexts[i] from a stored array.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ── helpers ──────────────────────────────────────────────────────── */

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

/* Resolver state: an array-backed contexts vector plus a counter so
 * tests can verify the resolver was actually invoked the expected
 * number of times. */
typedef struct {
    const uint16_t *contexts;
    size_t          calls;
    size_t          last_i;
    uint8_t         last_prev_sym;
} resolver_state;

/* Trivial resolver: returns contexts[i] from user_data, ignoring
 * prev_sym.  This is the parity test against the regular decoder. */
static uint16_t array_resolver(void *user_data, size_t i, uint8_t prev_sym)
{
    resolver_state *st = (resolver_state *)user_data;
    st->calls++;
    st->last_i = i;
    st->last_prev_sym = prev_sym;
    return st->contexts[i];
}

/* ── parity check ─────────────────────────────────────────────────── */

static int streaming_parity(const uint8_t *syms,
                            const uint16_t *ctxs,
                            size_t n,
                            uint16_t n_ctx,
                            const uint32_t (*freq)[256])
{
    uint32_t (*cum)[256] = (uint32_t (*)[256])calloc(n_ctx, 256 * sizeof(uint32_t));
    if (!cum) return 1;
    build_cum(n_ctx, freq, cum);

    uint8_t (*dtab)[TTIO_RANS_T] =
        (uint8_t (*)[TTIO_RANS_T])calloc(n_ctx, TTIO_RANS_T);
    if (!dtab) { free(cum); return 1; }

    int brc = ttio_rans_build_decode_table(n_ctx, freq,
                                           (const uint32_t (*)[256])cum, dtab);
    if (brc != TTIO_RANS_OK) {
        fprintf(stderr, "build_decode_table failed: %d\n", brc);
        free(cum); free(dtab); return 1;
    }

    /* Encode */
    size_t enc_cap = 32 + n * 4 + 256;
    uint8_t *enc_buf = (uint8_t *)malloc(enc_cap);
    if (!enc_buf) { free(cum); free(dtab); return 1; }
    size_t enc_len = enc_cap;
    int rc = ttio_rans_encode_block(syms, ctxs, n, n_ctx, freq, enc_buf, &enc_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode failed: %d\n", rc);
        free(enc_buf); free(cum); free(dtab); return 1;
    }

    /* Decode A: regular API */
    uint8_t *dec_a = (uint8_t *)calloc(n ? n : 1, 1);
    if (!dec_a) { free(enc_buf); free(cum); free(dtab); return 1; }
    rc = ttio_rans_decode_block(enc_buf, enc_len, ctxs, n_ctx, freq,
                                (const uint32_t (*)[256])cum,
                                (const uint8_t (*)[TTIO_RANS_T])dtab,
                                dec_a, n);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "regular decode failed: %d\n", rc);
        free(dec_a); free(enc_buf); free(cum); free(dtab); return 1;
    }

    /* Decode B: streaming API with array-backed resolver */
    uint8_t *dec_b = (uint8_t *)calloc(n ? n : 1, 1);
    if (!dec_b) { free(dec_a); free(enc_buf); free(cum); free(dtab); return 1; }
    resolver_state st = { ctxs, 0, 0, 0 };
    rc = ttio_rans_decode_block_streaming(enc_buf, enc_len, n_ctx, freq,
                                          (const uint32_t (*)[256])cum,
                                          (const uint8_t (*)[TTIO_RANS_T])dtab,
                                          dec_b, n,
                                          array_resolver, &st);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "streaming decode failed: %d\n", rc);
        free(dec_b); free(dec_a); free(enc_buf); free(cum); free(dtab); return 1;
    }

    /* Resolver invoked exactly n times */
    if (st.calls != n) {
        fprintf(stderr, "resolver call count mismatch: expected %zu got %zu\n",
                n, st.calls);
        free(dec_b); free(dec_a); free(enc_buf); free(cum); free(dtab); return 1;
    }

    /* Output must equal the original symbols AND the regular decoder. */
    int mismatch = 0;
    for (size_t i = 0; i < n; i++) {
        if (dec_b[i] != syms[i]) {
            fprintf(stderr, "streaming mismatch vs source at %zu: expected %u got %u\n",
                    i, syms[i], dec_b[i]);
            mismatch = 1; break;
        }
        if (dec_b[i] != dec_a[i]) {
            fprintf(stderr, "streaming mismatch vs regular at %zu: regular=%u streaming=%u\n",
                    i, dec_a[i], dec_b[i]);
            mismatch = 1; break;
        }
    }

    free(dec_b); free(dec_a); free(enc_buf); free(cum); free(dtab);
    return mismatch;
}

/* ── tests ────────────────────────────────────────────────────────── */

static void test_streaming_simple(void) {
    uint8_t s[]  = {0,1,2,3,0,1,2,3};
    uint16_t c[] = {0,0,0,0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=1024; f[0][2]=1024; f[0][3]=1024;
    assert(streaming_parity(s, c, 8, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_streaming_simple: PASS\n");
}

static void test_streaming_multi_context(void) {
    size_t n = 16;
    uint8_t s[]  = {0,1,0,1,2,3,2,3,0,0,1,1,2,2,3,3};
    uint16_t c[] = {0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,1};
    uint32_t f[2][256]; memset(f, 0, sizeof(f));
    f[0][0]=2048; f[0][1]=2048; f[1][2]=2048; f[1][3]=2048;
    assert(streaming_parity(s, c, n, 2, (const uint32_t (*)[256])f) == 0);
    printf("  test_streaming_multi_context: PASS\n");
}

static void test_streaming_not_divisible_by_4(void) {
    /* n=7: pad=1 — exercises the padding path on the streaming side */
    uint8_t s[]  = {0,1,2,3,0,1,2};
    uint16_t c[] = {0,0,0,0,0,0,0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0]=1024; f[0][1]=1024; f[0][2]=1024; f[0][3]=1024;
    assert(streaming_parity(s, c, 7, 1, (const uint32_t (*)[256])f) == 0);
    printf("  test_streaming_not_divisible_by_4: PASS\n");
}

static void test_streaming_large(void) {
    size_t n = 2000;
    uint8_t  *s = (uint8_t *) malloc(n);
    uint16_t *c = (uint16_t *)calloc(n, 2);
    assert(s && c);
    uint32_t rng = 12345;
    for (size_t i = 0; i < n; i++) {
        rng = rng*1103515245+12345; s[i] = (uint8_t)((rng>>16)&7);
        rng = rng*1103515245+12345; c[i] = (uint16_t)((rng>>16)&3);
    }
    uint32_t f[4][256]; memset(f, 0, sizeof(f));
    for (int ctx=0; ctx<4; ctx++) {
        f[ctx][0]=1024; f[ctx][1]=768; f[ctx][2]=640; f[ctx][3]=512;
        f[ctx][4]=384;  f[ctx][5]=320; f[ctx][6]=256; f[ctx][7]=192;
    }
    assert(streaming_parity(s, c, n, 4, (const uint32_t (*)[256])f) == 0);
    free(s); free(c);
    printf("  test_streaming_large: PASS\n");
}

/* Resolver that derives ctx from prev_sym — verifies the prev_sym
 * threading works.  We mirror this on the encode side by computing
 * the same contexts up-front, then both decoders should agree. */
static uint16_t prev_sym_resolver(void *user_data, size_t i, uint8_t prev_sym)
{
    (void)user_data;
    if (i == 0) return 0;
    return (uint16_t)(prev_sym & 1u);  /* 2 contexts based on prev parity */
}

static void test_streaming_prev_sym_dependency(void) {
    /* Build symbols and "true" contexts that the encoder will use.
     * contexts[i] = parity(symbols[i-1]) for i>0, else 0. */
    size_t n = 256;
    uint8_t  *s = (uint8_t *) malloc(n);
    uint16_t *c = (uint16_t *)malloc(n * sizeof(uint16_t));
    assert(s && c);
    uint32_t rng = 0xC0FFEE;
    for (size_t i = 0; i < n; i++) {
        rng = rng*1103515245+12345;
        s[i] = (uint8_t)((rng>>16) & 3);  /* alphabet {0,1,2,3} */
    }
    c[0] = 0;
    for (size_t i = 1; i < n; i++)
        c[i] = (uint16_t)(s[i-1] & 1u);

    uint32_t f[2][256]; memset(f, 0, sizeof(f));
    /* Both contexts can encode the full alphabet uniformly. */
    for (int ctx = 0; ctx < 2; ctx++) {
        f[ctx][0]=1024; f[ctx][1]=1024; f[ctx][2]=1024; f[ctx][3]=1024;
    }

    uint32_t cum[2][256]; build_cum(2, (const uint32_t (*)[256])f, cum);
    uint8_t dtab[2][TTIO_RANS_T];
    assert(ttio_rans_build_decode_table(2, (const uint32_t (*)[256])f,
                                        (const uint32_t (*)[256])cum, dtab) == TTIO_RANS_OK);

    size_t enc_cap = 32 + n * 4 + 256;
    uint8_t *enc = (uint8_t *)malloc(enc_cap);
    assert(enc);
    size_t enc_len = enc_cap;
    int rc = ttio_rans_encode_block(s, c, n, 2,
                                    (const uint32_t (*)[256])f, enc, &enc_len);
    assert(rc == TTIO_RANS_OK);

    /* Now decode using ONLY the prev-sym resolver, with NO contexts array. */
    uint8_t *dec = (uint8_t *)calloc(n, 1);
    assert(dec);
    rc = ttio_rans_decode_block_streaming(enc, enc_len, 2,
                                          (const uint32_t (*)[256])f,
                                          (const uint32_t (*)[256])cum,
                                          (const uint8_t (*)[TTIO_RANS_T])dtab,
                                          dec, n,
                                          prev_sym_resolver, NULL);
    assert(rc == TTIO_RANS_OK);
    for (size_t i = 0; i < n; i++) {
        if (dec[i] != s[i]) {
            fprintf(stderr, "prev-sym streaming mismatch at %zu: expected %u got %u\n",
                    i, s[i], dec[i]);
            assert(0);
        }
    }

    free(dec); free(enc); free(s); free(c);
    printf("  test_streaming_prev_sym_dependency: PASS\n");
}

/* Error-path tests */

static void test_streaming_err_null_resolver(void) {
    uint8_t  buf[64] = {0};
    uint8_t  out[4]  = {0};
    /* Need a valid-looking freq/cum/dtab so we hit the resolver check */
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0] = TTIO_RANS_T;
    uint32_t cum[1][256]; build_cum(1, (const uint32_t (*)[256])f, cum);
    uint8_t dtab[1][TTIO_RANS_T];
    assert(ttio_rans_build_decode_table(1, (const uint32_t (*)[256])f,
                                        (const uint32_t (*)[256])cum, dtab) == TTIO_RANS_OK);
    int rc = ttio_rans_decode_block_streaming(
        buf, sizeof(buf), 1,
        (const uint32_t (*)[256])f,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        out, 4, NULL, NULL);
    assert(rc == TTIO_RANS_ERR_PARAM);
    printf("  test_streaming_err_null_resolver: PASS\n");
}

static uint16_t out_of_range_resolver(void *user_data, size_t i, uint8_t prev_sym)
{
    (void)user_data; (void)i; (void)prev_sym;
    return 99;  /* Way out of range */
}

static void test_streaming_err_ctx_out_of_range(void) {
    /* Encode something valid first */
    uint8_t  s[] = {0,1,0,1};
    uint16_t c[] = {0,0,0,0};
    uint32_t f[2][256]; memset(f, 0, sizeof(f));
    f[0][0]=2048; f[0][1]=2048; f[1][0]=2048; f[1][1]=2048;
    uint32_t cum[2][256]; build_cum(2, (const uint32_t (*)[256])f, cum);
    uint8_t dtab[2][TTIO_RANS_T];
    assert(ttio_rans_build_decode_table(2, (const uint32_t (*)[256])f,
                                        (const uint32_t (*)[256])cum, dtab) == TTIO_RANS_OK);
    uint8_t enc[1024]; size_t enc_len = sizeof(enc);
    assert(ttio_rans_encode_block(s, c, 4, 2,
                                  (const uint32_t (*)[256])f, enc, &enc_len) == TTIO_RANS_OK);
    uint8_t dec[4];
    int rc = ttio_rans_decode_block_streaming(
        enc, enc_len, 2,
        (const uint32_t (*)[256])f,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        dec, 4,
        out_of_range_resolver, NULL);
    assert(rc == TTIO_RANS_ERR_PARAM);
    printf("  test_streaming_err_ctx_out_of_range: PASS\n");
}

static void test_streaming_empty_input(void) {
    /* n_symbols=0 should return OK without invoking the resolver.
     * (We still need valid freq/cum/dtab pointers — same convention as
     * the regular decoder kernel, which validates them up front.) */
    uint8_t  zhdr[32] = {0};
    uint8_t  outbuf[1] = {0};
    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    f[0][0] = TTIO_RANS_T;
    uint32_t cum[1][256]; build_cum(1, (const uint32_t (*)[256])f, cum);
    uint8_t dtab[1][TTIO_RANS_T];
    assert(ttio_rans_build_decode_table(1, (const uint32_t (*)[256])f,
                                        (const uint32_t (*)[256])cum, dtab) == TTIO_RANS_OK);
    resolver_state st = { NULL, 0, 0, 0 };
    int rc = ttio_rans_decode_block_streaming(
        zhdr, sizeof(zhdr), 1,
        (const uint32_t (*)[256])f,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        outbuf, 0,
        array_resolver, &st);
    assert(rc == TTIO_RANS_OK);
    assert(st.calls == 0);  /* resolver must not be invoked for empty input */
    printf("  test_streaming_empty_input: PASS\n");
}

/* ── main ─────────────────────────────────────────────────────────── */

int main(void)
{
    printf("ttio_rans streaming-decoder tests:\n");

    test_streaming_simple();
    test_streaming_multi_context();
    test_streaming_not_divisible_by_4();
    test_streaming_large();
    test_streaming_prev_sym_dependency();

    test_streaming_err_null_resolver();
    test_streaming_err_ctx_out_of_range();
    test_streaming_empty_input();

    printf("All streaming tests passed.\n");
    return 0;
}
