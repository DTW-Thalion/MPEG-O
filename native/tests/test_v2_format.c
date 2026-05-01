/*
 * test_v2_format.c -- Tests for the V2 multi-block wire format.
 *
 * Covers:
 *   * V2 single-block round-trip (reads_per_block large enough for one block)
 *   * V2 multi-block round-trip (forced 4+ blocks)
 *   * V2 header corruption detection (bad magic / version)
 *   * V2 block_count=0 with non-empty input → ERR_CORRUPT
 *   * V1 backwards compat (manually constructed V1 stream → decode_mt)
 *
 * The C library's V2 decode uses synthetic zero contexts when
 * reconstructing block contents.  This means it only round-trips
 * cleanly for streams where every symbol has the same context (the
 * test suite below is restricted to n_contexts=1 to enforce this).
 * Multi-context streams must be decoded via the Python ctypes layer
 * (Task 15) which supplies the original context vector.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ── helpers ───────────────────────────────────────────────────────── */

static void make_data(uint8_t *syms, uint16_t *ctxs, size_t n, uint32_t seed)
{
    uint32_t rng = seed;
    for (size_t i = 0; i < n; i++) {
        rng = rng * 1103515245u + 12345u;
        syms[i] = (uint8_t)((rng >> 16) & 0xFF);
        ctxs[i] = 0; /* single context */
    }
}

/* ── test_v2_single_block_roundtrip ────────────────────────────────── */

static void test_v2_single_block_roundtrip(void)
{
    const size_t n_reads = 4;
    const size_t read_len = 64;
    const size_t n = n_reads * read_len;

    uint8_t *syms = (uint8_t *)malloc(n);
    uint16_t *ctxs = (uint16_t *)calloc(n, sizeof(uint16_t));
    size_t *rls = (size_t *)malloc(n_reads * sizeof(size_t));
    assert(syms && ctxs && rls);
    for (size_t i = 0; i < n_reads; i++) rls[i] = read_len;
    make_data(syms, ctxs, n, 0x1234u);

    ttio_rans_pool *pool = ttio_rans_pool_create(2);
    assert(pool);

    size_t out_cap = 4096 + n * 4;
    uint8_t *enc = (uint8_t *)malloc(out_cap);
    assert(enc);
    size_t enc_len = out_cap;

    /* reads_per_block = 4 → 1 block */
    int rc = ttio_rans_encode_mt(pool, syms, ctxs, n,
                                 /*n_contexts*/1,
                                 /*reads_per_block*/4,
                                 rls, n_reads,
                                 enc, &enc_len);
    assert(rc == TTIO_RANS_OK);

    /* Verify wire format header */
    assert(enc[0] == 'M' && enc[1] == '9' && enc[2] == '4' && enc[3] == 'Z');
    assert(enc[4] == 2); /* version */
    uint32_t block_count = (uint32_t)enc[5]
                         | ((uint32_t)enc[6] << 8)
                         | ((uint32_t)enc[7] << 16)
                         | ((uint32_t)enc[8] << 24);
    assert(block_count == 1);

    uint8_t *dec = (uint8_t *)calloc(n, 1);
    assert(dec);
    size_t dec_n = n;
    rc = ttio_rans_decode_mt(pool, enc, enc_len, dec, &dec_n);
    assert(rc == TTIO_RANS_OK);
    assert(dec_n == n);
    assert(memcmp(dec, syms, n) == 0);

    free(dec); free(enc); free(rls); free(ctxs); free(syms);
    ttio_rans_pool_destroy(pool);
    printf("  test_v2_single_block_roundtrip: PASS\n");
}

/* ── test_v2_multi_block_roundtrip ─────────────────────────────────── */

static void test_v2_multi_block_roundtrip(void)
{
    const size_t n_reads = 16;
    const size_t read_len = 32;
    const size_t reads_per_block = 4; /* → 4 blocks */
    const size_t n = n_reads * read_len;

    uint8_t *syms = (uint8_t *)malloc(n);
    uint16_t *ctxs = (uint16_t *)calloc(n, sizeof(uint16_t));
    size_t *rls = (size_t *)malloc(n_reads * sizeof(size_t));
    assert(syms && ctxs && rls);
    for (size_t i = 0; i < n_reads; i++) rls[i] = read_len;
    make_data(syms, ctxs, n, 0xABCDu);

    ttio_rans_pool *pool = ttio_rans_pool_create(4);
    assert(pool);

    size_t out_cap = 65536 + n * 4;
    uint8_t *enc = (uint8_t *)malloc(out_cap);
    assert(enc);
    size_t enc_len = out_cap;

    int rc = ttio_rans_encode_mt(pool, syms, ctxs, n,
                                 /*n_contexts*/1,
                                 reads_per_block,
                                 rls, n_reads,
                                 enc, &enc_len);
    assert(rc == TTIO_RANS_OK);

    /* Verify block_count = 4 */
    uint32_t block_count = (uint32_t)enc[5]
                         | ((uint32_t)enc[6] << 8)
                         | ((uint32_t)enc[7] << 16)
                         | ((uint32_t)enc[8] << 24);
    assert(block_count == 4);

    uint8_t *dec = (uint8_t *)calloc(n, 1);
    assert(dec);
    size_t dec_n = n;
    rc = ttio_rans_decode_mt(pool, enc, enc_len, dec, &dec_n);
    assert(rc == TTIO_RANS_OK);
    assert(dec_n == n);
    assert(memcmp(dec, syms, n) == 0);

    free(dec); free(enc); free(rls); free(ctxs); free(syms);
    ttio_rans_pool_destroy(pool);
    printf("  test_v2_multi_block_roundtrip: PASS\n");
}

/* ── test_v2_header_corruption_detected ────────────────────────────── */

static void test_v2_header_corruption_detected(void)
{
    const size_t n_reads = 2;
    const size_t read_len = 32;
    const size_t n = n_reads * read_len;

    uint8_t *syms = (uint8_t *)malloc(n);
    uint16_t *ctxs = (uint16_t *)calloc(n, sizeof(uint16_t));
    size_t rls[2] = {read_len, read_len};
    assert(syms && ctxs);
    make_data(syms, ctxs, n, 0xCAFEu);

    ttio_rans_pool *pool = ttio_rans_pool_create(1);
    assert(pool);

    size_t out_cap = 4096 + n * 4;
    uint8_t *enc = (uint8_t *)malloc(out_cap);
    assert(enc);
    size_t enc_len = out_cap;

    int rc = ttio_rans_encode_mt(pool, syms, ctxs, n,
                                 /*n_contexts*/1,
                                 /*reads_per_block*/1,
                                 rls, n_reads,
                                 enc, &enc_len);
    assert(rc == TTIO_RANS_OK);

    uint8_t *dec = (uint8_t *)calloc(n, 1);
    assert(dec);

    /* 1) Corrupt magic byte */
    uint8_t saved_byte = enc[0];
    enc[0] = 'X';
    size_t dec_n = n;
    rc = ttio_rans_decode_mt(pool, enc, enc_len, dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_CORRUPT);
    enc[0] = saved_byte;

    /* 2) Corrupt version byte (set to 99) */
    saved_byte = enc[4];
    enc[4] = 99;
    dec_n = n;
    rc = ttio_rans_decode_mt(pool, enc, enc_len, dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_CORRUPT);
    enc[4] = saved_byte;

    /* 3) Truncated header */
    dec_n = n;
    rc = ttio_rans_decode_mt(pool, enc, /*comp_len*/3, dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_CORRUPT);

    /* Sanity: original buffer still decodes correctly */
    dec_n = n;
    rc = ttio_rans_decode_mt(pool, enc, enc_len, dec, &dec_n);
    assert(rc == TTIO_RANS_OK);
    assert(memcmp(dec, syms, n) == 0);

    free(dec); free(enc); free(ctxs); free(syms);
    ttio_rans_pool_destroy(pool);
    printf("  test_v2_header_corruption_detected: PASS\n");
}

/* ── test_v2_block_count_zero ──────────────────────────────────────── */

static void test_v2_block_count_zero(void)
{
    /* Construct a V2 header with block_count=0 and 17 bytes of data:
     * legal (zero-block stream → zero symbols decoded). */
    uint8_t v2_zero_blocks[17];
    memset(v2_zero_blocks, 0, sizeof(v2_zero_blocks));
    v2_zero_blocks[0] = 'M';
    v2_zero_blocks[1] = '9';
    v2_zero_blocks[2] = '4';
    v2_zero_blocks[3] = 'Z';
    v2_zero_blocks[4] = 2; /* version */
    /* block_count = 0 (already zeroed) */
    /* reads_per_block = 0 (already zeroed) */
    /* n_contexts in low 2 bytes of context_params */
    v2_zero_blocks[13] = 1;  /* n_contexts = 1 */
    v2_zero_blocks[14] = 0;

    ttio_rans_pool *pool = ttio_rans_pool_create(1);
    assert(pool);

    uint8_t dec[8];
    size_t dec_n = sizeof(dec);
    int rc = ttio_rans_decode_mt(pool, v2_zero_blocks, sizeof(v2_zero_blocks),
                                 dec, &dec_n);
    assert(rc == TTIO_RANS_OK);
    assert(dec_n == 0);

    /* Now: extra bytes after the header → ERR_CORRUPT (block_count=0 means
     * the stream MUST end at WF_V2_HDR_SIZE). */
    uint8_t v2_zero_with_extra[20];
    memcpy(v2_zero_with_extra, v2_zero_blocks, 17);
    v2_zero_with_extra[17] = 0xAA;
    v2_zero_with_extra[18] = 0xBB;
    v2_zero_with_extra[19] = 0xCC;

    dec_n = sizeof(dec);
    rc = ttio_rans_decode_mt(pool, v2_zero_with_extra, sizeof(v2_zero_with_extra),
                             dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_CORRUPT);

    ttio_rans_pool_destroy(pool);
    printf("  test_v2_block_count_zero: PASS\n");
}

/* ── test_v1_backcompat ────────────────────────────────────────────── *
 *
 * Manually construct a V1 stream and verify decode_mt round-trips.
 *
 *   magic(4) + version=1(1)
 *   n_block_symbols (uint32 LE, 4 bytes)
 *   n_contexts      (uint16 LE, 2 bytes)
 *   freq_table      n_contexts * 512 bytes
 *   rANS payload    rest of buffer (output of ttio_rans_encode_block)
 */

static void test_v1_backcompat(void)
{
    const size_t n = 256;
    uint8_t *syms = (uint8_t *)malloc(n);
    uint16_t *ctxs = (uint16_t *)calloc(n, sizeof(uint16_t));
    assert(syms && ctxs);
    make_data(syms, ctxs, n, 0xDEADu);

    /* Build a uniform freq table for 1 context (T=4096 split across
     * the 256 alphabet → 16 each). */
    uint32_t freq[1][256];
    for (int s = 0; s < 256; s++) freq[0][s] = 16;

    /* Encode payload via ttio_rans_encode_block */
    size_t payload_cap = 4096 + n * 4;
    uint8_t *payload = (uint8_t *)malloc(payload_cap);
    assert(payload);
    size_t payload_len = payload_cap;
    int rc = ttio_rans_encode_block(syms, ctxs, n, /*n_contexts*/1,
                                    (const uint32_t (*)[256])freq,
                                    payload, &payload_len);
    assert(rc == TTIO_RANS_OK);

    /* Build V1 stream:
     *   M 9 4 Z (1) (n_block_symbols u32) (n_contexts u16)
     *   freq_table (n_contexts * 512) | payload
     */
    size_t freq_bytes = 1 * 256 * 2;  /* uint16 LE per entry */
    size_t v1_header = 4 + 1 + 4 + 2 + freq_bytes;
    size_t v1_total = v1_header + payload_len;
    uint8_t *v1 = (uint8_t *)malloc(v1_total);
    assert(v1);
    v1[0]='M'; v1[1]='9'; v1[2]='4'; v1[3]='Z'; v1[4]=1;
    /* n_block_symbols = n */
    v1[5]  = (uint8_t)(n & 0xFF);
    v1[6]  = (uint8_t)((n >> 8) & 0xFF);
    v1[7]  = (uint8_t)((n >> 16) & 0xFF);
    v1[8]  = (uint8_t)((n >> 24) & 0xFF);
    /* n_contexts = 1 */
    v1[9]  = 1;
    v1[10] = 0;
    /* freq_table: 256 entries × uint16 LE */
    size_t fpos = 11;
    for (int s = 0; s < 256; s++) {
        v1[fpos]   = (uint8_t)(freq[0][s] & 0xFF);
        v1[fpos+1] = (uint8_t)((freq[0][s] >> 8) & 0xFF);
        fpos += 2;
    }
    /* payload */
    memcpy(v1 + fpos, payload, payload_len);

    /* Decode via V1 dispatch */
    ttio_rans_pool *pool = ttio_rans_pool_create(1);
    assert(pool);
    uint8_t *dec = (uint8_t *)calloc(n, 1);
    assert(dec);
    size_t dec_n = n;
    rc = ttio_rans_decode_mt(pool, v1, v1_total, dec, &dec_n);
    assert(rc == TTIO_RANS_OK);
    assert(dec_n == n);
    assert(memcmp(dec, syms, n) == 0);

    free(dec); free(v1); free(payload); free(ctxs); free(syms);
    ttio_rans_pool_destroy(pool);
    printf("  test_v1_backcompat: PASS\n");
}

/* ── test_v2_no_pool ───────────────────────────────────────────────── *
 *
 * Verify encode_mt / decode_mt also work with pool=NULL (sequential).
 */

static void test_v2_no_pool(void)
{
    const size_t n_reads = 4;
    const size_t read_len = 32;
    const size_t n = n_reads * read_len;

    uint8_t *syms = (uint8_t *)malloc(n);
    uint16_t *ctxs = (uint16_t *)calloc(n, sizeof(uint16_t));
    size_t *rls = (size_t *)malloc(n_reads * sizeof(size_t));
    assert(syms && ctxs && rls);
    for (size_t i = 0; i < n_reads; i++) rls[i] = read_len;
    make_data(syms, ctxs, n, 0xBEEFu);

    size_t out_cap = 4096 + n * 4;
    uint8_t *enc = (uint8_t *)malloc(out_cap);
    assert(enc);
    size_t enc_len = out_cap;

    int rc = ttio_rans_encode_mt(/*pool*/NULL, syms, ctxs, n,
                                 /*n_contexts*/1,
                                 /*reads_per_block*/2,
                                 rls, n_reads,
                                 enc, &enc_len);
    assert(rc == TTIO_RANS_OK);

    uint8_t *dec = (uint8_t *)calloc(n, 1);
    assert(dec);
    size_t dec_n = n;
    rc = ttio_rans_decode_mt(/*pool*/NULL, enc, enc_len, dec, &dec_n);
    assert(rc == TTIO_RANS_OK);
    assert(dec_n == n);
    assert(memcmp(dec, syms, n) == 0);

    free(dec); free(enc); free(rls); free(ctxs); free(syms);
    printf("  test_v2_no_pool: PASS\n");
}

/* ── test_v2_out_buf_too_small ─────────────────────────────────────── */

static void test_v2_out_buf_too_small(void)
{
    const size_t n_reads = 2;
    const size_t read_len = 64;
    const size_t n = n_reads * read_len;

    uint8_t *syms = (uint8_t *)malloc(n);
    uint16_t *ctxs = (uint16_t *)calloc(n, sizeof(uint16_t));
    size_t rls[2] = {read_len, read_len};
    assert(syms && ctxs);
    make_data(syms, ctxs, n, 0x4242u);

    /* Pass *out_len = 16 (too small) → ERR_PARAM with required size */
    uint8_t small[16];
    size_t out_len = sizeof(small);
    int rc = ttio_rans_encode_mt(/*pool*/NULL, syms, ctxs, n,
                                 /*n_contexts*/1,
                                 /*reads_per_block*/1,
                                 rls, n_reads,
                                 small, &out_len);
    assert(rc == TTIO_RANS_ERR_PARAM);
    assert(out_len > sizeof(small)); /* required size reported */

    free(ctxs); free(syms);
    printf("  test_v2_out_buf_too_small: PASS\n");
}

/* ── main ──────────────────────────────────────────────────────────── */

int main(void)
{
    printf("ttio_rans V2 wire-format tests:\n");
    test_v2_single_block_roundtrip();
    test_v2_multi_block_roundtrip();
    test_v2_header_corruption_detected();
    test_v2_block_count_zero();
    test_v1_backcompat();
    test_v2_no_pool();
    test_v2_out_buf_too_small();
    printf("All V2 wire-format tests passed.\n");
    return 0;
}
