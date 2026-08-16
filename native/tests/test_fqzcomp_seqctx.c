/* native/tests/test_fqzcomp_seqctx.c
 *
 * V5 sequence-context body coder: round-trips over the edge battery,
 * param-block bytes, and the error paths (NULL sequences, truncation,
 * bad parameters).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../src/fqzcomp_seqctx.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

static uint64_t xs(uint64_t *s) {
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}

/* Motif-correlated synthetic: base drawn from ACGTN, quality depends
 * on the base so sequence context is causal. */
static void make_corpus(uint8_t *qual, uint8_t *seq, uint32_t *lens,
                        size_t n_reads, uint32_t len, int lowercase) {
    static const uint8_t BU[5] = {'A','C','G','T','N'};
    static const uint8_t BL[5] = {'a','c','g','t','N'};
    const uint8_t *B = lowercase ? BL : BU;
    uint64_t s = 42;
    size_t k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        lens[r] = len;
        for (uint32_t i = 0; i < len; i++, k++) {
            uint8_t b = B[xs(&s) % 5];
            seq[k] = b;
            qual[k] = (uint8_t)(33 + ((b | 0x20) == 'g' ? 8 : 30)
                                + (xs(&s) % 8));
        }
    }
}

int main(void) {
    enum { NR = 300, LEN = 100, N = NR * LEN };
    uint8_t *qual = malloc(N), *seq = malloc(N), *back = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    make_corpus(qual, seq, lens, NR, LEN, 0);

    uint8_t *out = malloc(N + (1 << 16));
    size_t out_cap = N + (1 << 16);
    size_t out_len = out_cap;
    int rc = ttio_fqz_seqctx_compress(qual, N, lens, NR, seq,
                                      &TTIO_SEQCTX_S5, out, &out_len);
    CHECK(rc == 0, "S5 compress rc");
    CHECK(out_len > 8 && out_len < N, "S5 output smaller than input");
    CHECK(out[0] == 1 && out[1] == 5 && out[2] == 6 && out[3] == 5
          && out[4] == 7 && out[5] == 0 && out[6] == 5 && out[7] == 0,
          "S5 param block bytes");

    memset(back, 0, N);
    rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, seq, back, N);
    CHECK(rc == 0, "S5 uncompress rc");
    CHECK(memcmp(back, qual, N) == 0, "S5 round trip bit-exact");
    size_t s5_len = out_len;

    out_len = out_cap;
    rc = ttio_fqz_seqctx_compress(qual, N, lens, NR, seq,
                                  &TTIO_SEQCTX_S6, out, &out_len);
    CHECK(rc == 0, "S6 compress rc");
    memset(back, 0, N);
    rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, seq, back, N);
    CHECK(rc == 0 && memcmp(back, qual, N) == 0, "S6 round trip");

    rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, NULL, back, N);
    CHECK(rc == TTIO_SEQCTX_ERR_NO_SEQ, "NULL seq rejected");

    rc = ttio_fqz_seqctx_uncompress(out, 4, lens, NR, seq, back, N);
    CHECK(rc == TTIO_SEQCTX_ERR_CORRUPT, "truncated body rejected");

    /* Lowercase bases: same bcode, so the S5 stream size matches the
     * uppercase twin exactly (same qualities, same base codes). */
    {
        uint8_t *qual2 = malloc(N), *seq2 = malloc(N);
        uint32_t *lens2 = malloc(NR * sizeof(*lens2));
        make_corpus(qual2, seq2, lens2, NR, LEN, 1);
        CHECK(memcmp(qual2, qual, N) == 0, "lowercase twin same qualities");
        out_len = out_cap;
        rc = ttio_fqz_seqctx_compress(qual2, N, lens2, NR, seq2,
                                      &TTIO_SEQCTX_S5, out, &out_len);
        CHECK(rc == 0 && out_len == s5_len,
              "lowercase bases map to the same codes");
        memset(back, 0, N);
        rc = ttio_fqz_seqctx_uncompress(out, out_len, lens2, NR, seq2,
                                        back, N);
        CHECK(rc == 0 && memcmp(back, qual2, N) == 0,
              "lowercase round trip");
        free(qual2); free(seq2); free(lens2);
    }

    /* Wide quality alphabet (33..126, HiFi-like) round-trips. */
    {
        uint8_t *qw = malloc(N);
        uint64_t s = 7;
        for (size_t k = 0; k < N; k++)
            qw[k] = (uint8_t)(33 + (xs(&s) % 94));
        out_len = out_cap;
        rc = ttio_fqz_seqctx_compress(qw, N, lens, NR, seq,
                                      &TTIO_SEQCTX_S6, out, &out_len);
        CHECK(rc == 0, "wide alphabet compresses");
        memset(back, 0, N);
        rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, seq,
                                        back, N);
        CHECK(rc == 0 && memcmp(back, qw, N) == 0,
              "wide alphabet round trip");
        free(qw);
    }

    /* Edge: single 1-base read with an N base. */
    {
        uint32_t l1[1] = {1};
        uint8_t q1 = 70, s1 = 'N', b1 = 0;
        out_len = 1 << 16;
        rc = ttio_fqz_seqctx_compress(&q1, 1, l1, 1, &s1,
                                      &TTIO_SEQCTX_S5, out, &out_len);
        CHECK(rc == 0, "single N-base read compresses");
        rc = ttio_fqz_seqctx_uncompress(out, out_len, l1, 1, &s1, &b1, 1);
        CHECK(rc == 0 && b1 == 70, "single read round trips");
    }

    /* Edge: empty input yields the bare param block. */
    out_len = 1 << 16;
    rc = ttio_fqz_seqctx_compress(NULL, 0, NULL, 0, NULL,
                                  &TTIO_SEQCTX_S5, out, &out_len);
    CHECK(rc == 0 && out_len == 8, "empty input yields bare param block");

    /* Bad parameters rejected. */
    {
        ttio_seqctx_param bad = { 7, 12, 5, 7, 0, 5 };  /* 24 ctx bits */
        out_len = out_cap;
        rc = ttio_fqz_seqctx_compress(qual, N, lens, NR, seq,
                                      &bad, out, &out_len);
        CHECK(rc == TTIO_SEQCTX_ERR_PARAM, "oversized ctx rejected");
    }

    /* Length mismatch rejected on both sides. */
    rc = ttio_fqz_seqctx_compress(qual, N - 1, lens, NR, seq,
                                  &TTIO_SEQCTX_S5, out, &out_len);
    CHECK(rc == TTIO_SEQCTX_ERR_ARGS, "length mismatch rejected");

    printf("%s: %d failures\n", __FILE__, failures);
    free(qual); free(seq); free(back); free(lens); free(out);
    return failures ? 1 : 0;
}
