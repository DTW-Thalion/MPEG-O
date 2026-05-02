/*
 * test_adaptive_roundtrip.c — encode/decode parity for the adaptive
 * M94.Z kernel. 1000 symbols × 10 reads × 100bp = 100K input.
 *
 * Verifies:
 *  - encode succeeds
 *  - decode succeeds
 *  - decoded symbols == original input bytes
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    const uint16_t qbits = 12, pbits = 2, sloc = 14;
    const uint16_t max_sym = 94;
    const size_t n_reads = 10;
    const uint32_t read_len = 100;
    const size_t n_symbols = n_reads * read_len;

    uint8_t *symbols = (uint8_t *)malloc(n_symbols);
    uint16_t *contexts = (uint16_t *)malloc(n_symbols * sizeof(uint16_t));
    uint32_t *read_lengths = (uint32_t *)malloc(n_reads * sizeof(uint32_t));
    uint8_t *revcomp = (uint8_t *)malloc(n_reads);
    if (!symbols || !contexts || !read_lengths || !revcomp) return 1;

    /* Synthesise Q-values directly in [20, 41) so max_sym = 94 covers them. */
    uint64_t s = 0xBEEFULL;
    for (size_t i = 0; i < n_symbols; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        symbols[i] = (uint8_t)(20u + (uint8_t)((s >> 32) % 21u));
    }
    for (size_t r = 0; r < n_reads; r++) {
        read_lengths[r] = read_len;
        revcomp[r] = (uint8_t)(r & 1u);
    }

    /* Build sparse contexts via M94.Z context formula. Mirrors the
     * decoder's inline derivation exactly so the dense ids match. */
    const uint32_t shift = qbits / 3u;
    const uint32_t qmask = (1u << qbits) - 1u;
    const uint32_t shift_mask = (1u << shift) - 1u;
    const uint32_t ctx_cap_sparse = 1u << sloc;
    uint16_t *ctx_remap = (uint16_t *)malloc(ctx_cap_sparse * sizeof(uint16_t));
    if (!ctx_remap) return 1;
    for (uint32_t c = 0; c < ctx_cap_sparse; c++) ctx_remap[c] = 0xFFFFu;

    uint16_t *sparse_seq = (uint16_t *)malloc(n_symbols * sizeof(uint16_t));
    if (!sparse_seq) return 1;
    {
        size_t ridx = 0;
        uint32_t pir = 0;
        uint32_t crl = read_lengths[0];
        uint32_t crc = revcomp[0];
        size_t cend = crl;
        uint32_t pq = 0;
        for (size_t i = 0; i < n_symbols; i++) {
            if (i > 0) {
                pq = ((pq << shift)
                      | ((uint32_t)symbols[i - 1] & shift_mask)) & qmask;
                pir += 1u;
            }
            if (i > 0 && i >= cend && ridx + 1 < n_reads) {
                ridx += 1;
                pir = 0;
                crl = read_lengths[ridx];
                crc = revcomp[ridx];
                cend += crl;
                pq = 0;
            }
            uint32_t pb;
            if (pbits == 0) pb = 0;
            else {
                uint32_t n_buckets = 1u << pbits;
                if (crl == 0 || pir == 0) pb = 0;
                else if (pir >= crl) pb = n_buckets - 1u;
                else {
                    uint64_t prod = (uint64_t)pir * (uint64_t)n_buckets;
                    uint32_t bb = (uint32_t)(prod / (uint64_t)crl);
                    pb = (bb < n_buckets - 1u) ? bb : (n_buckets - 1u);
                }
            }
            uint32_t pmask = (1u << pbits) - 1u;
            uint32_t smask = (1u << sloc) - 1u;
            uint32_t ctx = pq & qmask;
            ctx |= (pb & pmask) << qbits;
            ctx |= (crc & 1u) << (qbits + pbits);
            ctx &= smask;
            sparse_seq[i] = (uint16_t)ctx;
        }
    }
    uint16_t n_contexts = 0;
    for (size_t i = 0; i < n_symbols; i++) {
        uint16_t cs = sparse_seq[i];
        if (ctx_remap[cs] == 0xFFFFu) {
            ctx_remap[cs] = n_contexts++;
        }
        contexts[i] = ctx_remap[cs];
    }

    /* Encode. */
    size_t out_cap = n_symbols * 4u + 64u;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) return 1;
    size_t out_len = out_cap;
    int rc = ttio_rans_encode_block_adaptive(
        symbols, contexts, n_symbols,
        n_contexts, max_sym,
        out, &out_len);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "encode failed rc=%d\n", rc);
        return 2;
    }
    fprintf(stderr, "  encoded %zu symbols -> %zu bytes\n", n_symbols, out_len);

    /* Decode. */
    uint8_t *decoded = (uint8_t *)malloc(n_symbols);
    if (!decoded) return 1;
    ttio_m94z_params params = { .qbits = qbits, .pbits = pbits, .sloc = sloc };
    rc = ttio_rans_decode_block_adaptive_m94z(
        out, out_len,
        n_contexts, max_sym,
        &params, ctx_remap,
        read_lengths, n_reads, revcomp,
        /* pad_ctx_dense */ 0,
        decoded, n_symbols);
    if (rc != TTIO_RANS_OK) {
        fprintf(stderr, "decode failed rc=%d\n", rc);
        return 3;
    }

    /* Verify. */
    if (memcmp(decoded, symbols, n_symbols) != 0) {
        fprintf(stderr, "FAIL: decoded != input\n");
        for (size_t i = 0; i < n_symbols && i < 20; i++) {
            if (decoded[i] != symbols[i]) {
                fprintf(stderr, "  diff at i=%zu: got=%u want=%u\n",
                        i, decoded[i], symbols[i]);
                break;
            }
        }
        return 4;
    }

    fprintf(stderr, "test_adaptive_roundtrip: PASS (n=%zu, ratio=%.3f B/sym)\n",
            n_symbols, (double)out_len / (double)n_symbols);

    free(decoded); free(out); free(sparse_seq); free(ctx_remap);
    free(revcomp); free(read_lengths); free(contexts); free(symbols);
    return 0;
}
