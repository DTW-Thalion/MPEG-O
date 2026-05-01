#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(void) {
    const size_t n = 10 * 1024 * 1024; /* 10 MiB */
    const uint16_t n_contexts = 1;
    const int n_iter = 5;

    printf("ttio_rans throughput benchmark\n");
    printf("kernel: %s\n", ttio_rans_kernel_name());
    printf("data:   %.1f MiB, %d iterations\n\n", n / (1024.0 * 1024.0), n_iter);

    /* Generate quality-like data: Q20-Q40 with LCG */
    uint8_t *symbols = malloc(n);
    uint16_t *contexts = calloc(n, sizeof(uint16_t));
    if (!symbols || !contexts) {
        fprintf(stderr, "alloc failed\n");
        return 1;
    }

    uint64_t s = 0xBEEFULL;
    for (size_t i = 0; i < n; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        symbols[i] = (uint8_t)(20 + ((s >> 33) % 21));  /* Q20..Q40 */
    }

    /* Build a freq table from the data */
    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    uint64_t counts[256] = {0};
    for (size_t i = 0; i < n; i++) counts[symbols[i]]++;

    /* Normalize to T=4096 */
    uint32_t total = 0;
    for (int i = 0; i < 256; i++) {
        if (counts[i] > 0) {
            freq[0][i] = (uint32_t)((counts[i] * TTIO_RANS_T) / n);
            if (freq[0][i] == 0) freq[0][i] = 1;
            total += freq[0][i];
        }
    }
    /* Fix up to exactly T */
    while (total < TTIO_RANS_T) {
        for (int i = 0; i < 256 && total < TTIO_RANS_T; i++) {
            if (freq[0][i] > 0) { freq[0][i]++; total++; }
        }
    }
    while (total > TTIO_RANS_T) {
        for (int i = 0; i < 256 && total > TTIO_RANS_T; i++) {
            if (freq[0][i] > 1) { freq[0][i]--; total--; }
        }
    }

    uint32_t cum[1][256];
    cum[0][0] = 0;
    for (int i = 1; i < 256; i++) cum[0][i] = cum[0][i-1] + freq[0][i-1];

    uint8_t (*dtab)[TTIO_RANS_T] = malloc(sizeof(*dtab));
    if (!dtab) { fprintf(stderr, "alloc failed\n"); return 1; }
    if (ttio_rans_build_decode_table(n_contexts, freq, cum, dtab) != 0) {
        fprintf(stderr, "decode table build failed\n");
        return 1;
    }

    /* Allocate output buffer (worst case) */
    size_t out_cap = n * 2 + 64;
    uint8_t *encoded = malloc(out_cap);
    uint8_t *decoded = malloc(n);
    if (!encoded || !decoded) {
        fprintf(stderr, "alloc failed\n");
        return 1;
    }

    /* Encode benchmark */
    double t_enc_total = 0;
    size_t enc_len = 0;
    for (int iter = 0; iter < n_iter; iter++) {
        size_t cap = out_cap;
        double t0 = now_seconds();
        int rc = ttio_rans_encode_block(symbols, contexts, n, n_contexts, freq, encoded, &cap);
        double t1 = now_seconds();
        if (rc != 0) {
            fprintf(stderr, "encode failed: rc=%d\n", rc);
            return 1;
        }
        t_enc_total += (t1 - t0);
        enc_len = cap;
    }
    double t_enc_avg = t_enc_total / n_iter;
    double enc_mbps = (n / (1024.0 * 1024.0)) / t_enc_avg;
    double ratio = (double)enc_len / n;

    /* Decode benchmark */
    double t_dec_total = 0;
    for (int iter = 0; iter < n_iter; iter++) {
        double t0 = now_seconds();
        int rc = ttio_rans_decode_block(encoded, enc_len, contexts, n_contexts, freq, cum, dtab, decoded, n);
        double t1 = now_seconds();
        if (rc != 0) {
            fprintf(stderr, "decode failed: rc=%d\n", rc);
            return 1;
        }
        t_dec_total += (t1 - t0);
    }
    double t_dec_avg = t_dec_total / n_iter;
    double dec_mbps = (n / (1024.0 * 1024.0)) / t_dec_avg;

    /* Verify */
    if (memcmp(symbols, decoded, n) != 0) {
        fprintf(stderr, "round-trip mismatch!\n");
        return 1;
    }

    printf("encode: %.1f MiB/s (%.3f s/iter, ratio %.3f)\n", enc_mbps, t_enc_avg, ratio);
    printf("decode: %.1f MiB/s (%.3f s/iter)\n", dec_mbps, t_dec_avg);
    printf("OK\n");

    free(symbols);
    free(contexts);
    free(encoded);
    free(decoded);
    free(dtab);
    return 0;
}
