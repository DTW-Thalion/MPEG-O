/*
 * test_m94z_decode.c — Parity test for ttio_rans_decode_block_m94z.
 *
 * Builds a synthetic 1000-symbol input split into 10 reads × 100bp each,
 * encodes with M94.Z context derivation done in C-side test code, and
 * decodes with two different APIs:
 *
 *   A) the streaming/callback API with a resolver mirroring the M94.Z
 *      formula
 *   B) the new ttio_rans_decode_block_m94z entry point with inline
 *      context derivation
 *
 * Both must produce the original symbols byte-for-byte.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */

#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ── M94.Z context formula (same as in rans_decode_m94z.c) ────────── */

static inline uint32_t pos_bucket(uint32_t pos, uint32_t rl, uint32_t pbits)
{
    if (pbits == 0) return 0;
    uint32_t n = 1u << pbits;
    if (rl == 0 || pos == 0) return 0;
    if (pos >= rl) return n - 1u;
    uint32_t b = (uint32_t)(((uint64_t)pos * (uint64_t)n) / (uint64_t)rl);
    return b < n - 1u ? b : n - 1u;
}

static inline uint32_t pack_ctx(uint32_t prev_q, uint32_t pb, uint32_t rc,
                                uint32_t qbits, uint32_t pbits, uint32_t sloc)
{
    uint32_t qmask = (1u << qbits) - 1u;
    uint32_t pmask = (1u << pbits) - 1u;
    uint32_t smask = (1u << sloc) - 1u;
    uint32_t ctx = prev_q & qmask;
    ctx |= (pb & pmask) << qbits;
    ctx |= (rc & 1u) << (qbits + pbits);
    return ctx & smask;
}

/* Resolver state for the streaming-API parity arm. */
typedef struct {
    uint32_t qbits, pbits, sloc;
    const uint32_t *read_lengths;
    const uint8_t  *revcomp_flags;
    size_t          n_reads;
    const uint16_t *ctx_remap;
    uint16_t        n_contexts;
    uint16_t        pad_ctx_dense;
    /* mutable state */
    size_t   read_idx;
    uint32_t pos_in_read;
    uint32_t cur_read_len;
    uint32_t cur_revcomp;
    size_t   cum_read_end;
    uint32_t prev_q;
} m94z_state;

static uint16_t resolver(void *ud, size_t i, uint8_t prev_sym)
{
    m94z_state *st = (m94z_state *)ud;
    uint32_t shift = (st->qbits / 3u) > 0 ? (st->qbits / 3u) : 1u;
    uint32_t qmask_local = (1u << st->qbits) - 1u;
    uint32_t shift_mask  = (1u << shift) - 1u;

    if (i > 0) {
        st->prev_q = ((st->prev_q << shift)
                      | ((uint32_t)prev_sym & shift_mask)) & qmask_local;
        st->pos_in_read += 1u;
    }
    if (i > 0 && i >= st->cum_read_end
        && st->read_idx + 1 < st->n_reads) {
        st->read_idx     += 1;
        st->pos_in_read   = 0;
        st->cur_read_len  = st->read_lengths[st->read_idx];
        st->cur_revcomp   = (uint32_t)st->revcomp_flags[st->read_idx];
        st->cum_read_end += st->cur_read_len;
        st->prev_q        = 0;
    }
    uint32_t pb = pos_bucket(st->pos_in_read, st->cur_read_len, st->pbits);
    uint32_t cs = pack_ctx(st->prev_q, pb, st->cur_revcomp & 1u,
                           st->qbits, st->pbits, st->sloc);
    uint16_t mapped = st->ctx_remap[cs];
    return mapped < st->n_contexts ? mapped : st->pad_ctx_dense;
}

/* ── Test driver ──────────────────────────────────────────────────── */

int main(void)
{
    const uint32_t qbits = 12, pbits = 2, sloc = 14;
    const size_t n_reads = 10;
    const uint32_t read_len = 100;
    const size_t n_symbols = n_reads * read_len;

    /* Synthetic Q20–Q40 quality stream. */
    uint8_t *symbols = (uint8_t *)malloc(n_symbols);
    if (!symbols) { fprintf(stderr, "alloc symbols\n"); return 1; }
    {
        uint64_t s = 0xBEEFULL;
        for (size_t i = 0; i < n_symbols; i++) {
            s = s * 6364136223846793005ULL + 1442695040888963407ULL;
            symbols[i] = (uint8_t)(33u + 20u + ((s >> 32) % 21u));
        }
    }

    uint32_t *read_lengths = (uint32_t *)malloc(n_reads * sizeof(uint32_t));
    uint8_t  *revcomp      = (uint8_t  *)malloc(n_reads);
    if (!read_lengths || !revcomp) { fprintf(stderr, "alloc reads\n"); return 1; }
    for (size_t r = 0; r < n_reads; r++) {
        read_lengths[r] = read_len;
        revcomp[r] = (r & 1u);
    }

    /* Build sparse contexts[] by walking the M94.Z formula directly,
     * then build the dense remap table. */
    const uint32_t ctx_cap_sparse = 1u << sloc;
    uint16_t *ctx_remap = (uint16_t *)malloc(ctx_cap_sparse * sizeof(uint16_t));
    if (!ctx_remap) { fprintf(stderr, "alloc ctx_remap\n"); return 1; }
    for (uint32_t c = 0; c < ctx_cap_sparse; c++) ctx_remap[c] = 0xFFFFu;

    uint16_t *ctx_sparse_seq = (uint16_t *)malloc(n_symbols * sizeof(uint16_t));
    if (!ctx_sparse_seq) { fprintf(stderr, "alloc ctxseq\n"); return 1; }
    {
        uint32_t shift = (qbits / 3u) > 0 ? (qbits / 3u) : 1u;
        uint32_t qmask_local = (1u << qbits) - 1u;
        uint32_t shift_mask  = (1u << shift) - 1u;
        size_t   ridx = 0;
        uint32_t pir = 0;
        uint32_t crl = read_lengths[0];
        uint32_t crc = revcomp[0];
        size_t   cend = crl;
        uint32_t pq = 0;

        for (size_t i = 0; i < n_symbols; i++) {
            if (i > 0) {
                pq = ((pq << shift)
                      | ((uint32_t)symbols[i - 1] & shift_mask)) & qmask_local;
                pir += 1u;
            }
            if (i > 0 && i >= cend && ridx + 1 < n_reads) {
                ridx += 1;
                pir   = 0;
                crl   = read_lengths[ridx];
                crc   = revcomp[ridx];
                cend += crl;
                pq    = 0;
            }
            uint32_t pb = pos_bucket(pir, crl, pbits);
            uint32_t cs = pack_ctx(pq, pb, crc & 1u, qbits, pbits, sloc);
            ctx_sparse_seq[i] = (uint16_t)cs;
        }
    }

    /* Build dense remap by scanning sparse_seq in encounter order. */
    uint16_t *active = (uint16_t *)malloc(ctx_cap_sparse * sizeof(uint16_t));
    if (!active) { fprintf(stderr, "alloc active\n"); return 1; }
    uint16_t n_contexts = 0;
    for (size_t i = 0; i < n_symbols; i++) {
        uint16_t cs = ctx_sparse_seq[i];
        if (ctx_remap[cs] == 0xFFFFu) {
            ctx_remap[cs] = n_contexts;
            active[n_contexts] = cs;
            n_contexts += 1;
        }
    }

    /* Build dense contexts[] for the encoder. */
    uint16_t *contexts = (uint16_t *)malloc(n_symbols * sizeof(uint16_t));
    if (!contexts) { fprintf(stderr, "alloc dense ctx\n"); return 1; }
    for (size_t i = 0; i < n_symbols; i++)
        contexts[i] = ctx_remap[ctx_sparse_seq[i]];

    /* Build per-DENSE-context freq[256] from this same sample. */
    uint32_t (*freq)[256] = (uint32_t (*)[256])calloc(n_contexts,
                                                      256 * sizeof(uint32_t));
    if (!freq) { fprintf(stderr, "alloc freq\n"); return 1; }
    {
        uint32_t (*raw)[256] = (uint32_t (*)[256])calloc(n_contexts,
                                                         256 * sizeof(uint32_t));
        if (!raw) { fprintf(stderr, "alloc raw\n"); return 1; }
        for (size_t i = 0; i < n_symbols; i++)
            raw[contexts[i]][symbols[i]] += 1;

        /* Normalise each context's row so sum == TTIO_RANS_T = 4096. */
        for (uint16_t c = 0; c < n_contexts; c++) {
            uint32_t total = 0;
            for (int s = 0; s < 256; s++) total += raw[c][s];
            if (total == 0) {
                freq[c][0] = TTIO_RANS_T;
                continue;
            }
            uint32_t scaled = 0;
            for (int s = 0; s < 256; s++) {
                if (raw[c][s] > 0) {
                    /* scaled = max(1, round(cnt * T / total)) */
                    uint64_t v = ((uint64_t)raw[c][s] * (uint64_t)TTIO_RANS_T
                                  + (uint64_t)total / 2u) / (uint64_t)total;
                    if (v == 0) v = 1;
                    freq[c][s] = (uint32_t)v;
                    scaled += freq[c][s];
                }
            }
            /* Adjust to exact T by tweaking the largest slot. */
            int delta = (int)TTIO_RANS_T - (int)scaled;
            if (delta != 0) {
                int best = 0;
                for (int s = 1; s < 256; s++)
                    if (freq[c][s] > freq[c][best]) best = s;
                int adjusted = (int)freq[c][best] + delta;
                if (adjusted < 1) adjusted = 1;
                freq[c][best] = (uint32_t)adjusted;
                /* Fix up rounding drift if best moved. */
                uint32_t recheck = 0;
                for (int s = 0; s < 256; s++) recheck += freq[c][s];
                if (recheck != TTIO_RANS_T) {
                    int d = (int)TTIO_RANS_T - (int)recheck;
                    int add_to = best;
                    int candidate = (int)freq[c][add_to] + d;
                    if (candidate < 1) {
                        for (int s = 0; s < 256; s++)
                            if (freq[c][s] >= 2u) { add_to = s; break; }
                    }
                    freq[c][add_to] = (uint32_t)((int)freq[c][add_to] + d);
                }
            }
        }
        free(raw);
    }

    /* Build cum and dtab from freq. */
    uint32_t (*cum)[256] = (uint32_t (*)[256])calloc(n_contexts,
                                                     256 * sizeof(uint32_t));
    if (!cum) { fprintf(stderr, "alloc cum\n"); return 1; }
    for (uint16_t c = 0; c < n_contexts; c++) {
        uint32_t r = 0;
        for (int s = 0; s < 256; s++) {
            cum[c][s] = r;
            r += freq[c][s];
        }
    }
    uint8_t (*dtab)[TTIO_RANS_T] = (uint8_t (*)[TTIO_RANS_T])calloc(
        n_contexts, TTIO_RANS_T);
    if (!dtab) { fprintf(stderr, "alloc dtab\n"); return 1; }
    int brc = ttio_rans_build_decode_table(n_contexts, freq,
                                           (const uint32_t (*)[256])cum, dtab);
    if (brc != TTIO_RANS_OK) {
        fprintf(stderr, "build_decode_table: %d\n", brc); return 1;
    }

    /* Encode. */
    size_t enc_cap = 64 + n_symbols * 4;
    uint8_t *enc = (uint8_t *)malloc(enc_cap);
    if (!enc) { fprintf(stderr, "alloc enc\n"); return 1; }
    size_t enc_len = enc_cap;
    int rc = ttio_rans_encode_block(symbols, contexts, n_symbols,
                                    n_contexts, freq, enc, &enc_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode_block: %d\n", rc); return 1;
    }

    /* Decode A: streaming with M94.Z resolver. */
    uint8_t *dec_a = (uint8_t *)calloc(n_symbols, 1);
    if (!dec_a) { fprintf(stderr, "alloc dec_a\n"); return 1; }
    m94z_state st = {
        .qbits = qbits, .pbits = pbits, .sloc = sloc,
        .read_lengths = read_lengths, .revcomp_flags = revcomp,
        .n_reads = n_reads, .ctx_remap = ctx_remap,
        .n_contexts = n_contexts, .pad_ctx_dense = 0,
        .read_idx = 0, .pos_in_read = 0,
        .cur_read_len = read_lengths[0],
        .cur_revcomp = revcomp[0],
        .cum_read_end = read_lengths[0],
        .prev_q = 0,
    };
    rc = ttio_rans_decode_block_streaming(
        enc, enc_len, n_contexts, freq,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        dec_a, n_symbols, resolver, &st);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "decode_streaming: %d\n", rc); return 1;
    }
    if (memcmp(dec_a, symbols, n_symbols) != 0) {
        fprintf(stderr, "FAIL: streaming output != input\n"); return 2;
    }

    /* Decode B: new m94z entry point with inline context derivation. */
    uint8_t *dec_b = (uint8_t *)calloc(n_symbols, 1);
    if (!dec_b) { fprintf(stderr, "alloc dec_b\n"); return 1; }
    ttio_m94z_params params = { .qbits = qbits, .pbits = pbits, .sloc = sloc };
    rc = ttio_rans_decode_block_m94z(
        enc, enc_len, n_contexts, freq,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        &params, ctx_remap, read_lengths, n_reads, revcomp,
        /* pad_ctx_dense */ 0,
        dec_b, n_symbols);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "decode_m94z: %d\n", rc); return 1;
    }
    if (memcmp(dec_b, symbols, n_symbols) != 0) {
        fprintf(stderr, "FAIL: m94z output != input\n"); return 3;
    }

    /* Decode A vs B byte-exact equivalence. */
    if (memcmp(dec_a, dec_b, n_symbols) != 0) {
        fprintf(stderr, "FAIL: streaming != m94z output\n"); return 4;
    }

    printf("ttio_rans_decode_block_m94z: PASS (%zu symbols, %u contexts)\n",
           n_symbols, (unsigned)n_contexts);

    free(dec_b); free(dec_a); free(enc);
    free(dtab); free(cum); free(freq); free(contexts);
    free(active); free(ctx_sparse_seq); free(ctx_remap);
    free(revcomp); free(read_lengths); free(symbols);
    return 0;
}
