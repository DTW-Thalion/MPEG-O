/* native/tests/test_m94z_v6_chain.c
 *
 * V6 single-chain qualities coder: round-trip, byte determinism,
 * output-capacity handling and parameter validation.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/m94z_v6.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

static uint64_t xs(uint64_t *s) {
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}

/* Same shape as the umbrella corpus: quality follows the current base
 * plus two bits of noise. V6 has no sequence field, so it sees this as
 * a quality stream with strong local structure. */
static void make_corpus(uint8_t *qual, uint8_t *seq, uint32_t *lens,
                        size_t n_reads, uint32_t len) {
    static const uint8_t B[4] = {'A','C','G','T'};
    uint64_t s = 42;
    size_t k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        lens[r] = len;
        for (uint32_t i = 0; i < len; i++, k++) {
            unsigned bi = (unsigned)(xs(&s) % 4);
            seq[k] = B[bi];
            qual[k] = (uint8_t)(40 + 10 * bi + (xs(&s) % 4));
        }
    }
}

int main(void) {
    enum { NR = 2000, LEN = 100, N = NR * LEN };
    uint8_t  *qual = malloc(N), *seq = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    make_corpus(qual, seq, lens, NR, LEN);

    size_t   cap = N + (1 << 16);
    uint8_t *enc = malloc(cap), *enc2 = malloc(cap);
    uint8_t *dec = malloc(N);

    ttio_v6_alphabet ab;
    ttio_v6_alphabet_build(qual, N, &ab);

    size_t l1 = cap;
    int rc = ttio_v6_chain_encode(&TTIO_V6_DEFAULT, &ab, qual, lens, NR, enc, &l1);
    CHECK(rc == 0, "chain encode rc");
    CHECK(l1 > 0 && l1 < (size_t)N, "chain output is smaller than input");

    rc = ttio_v6_chain_decode(&TTIO_V6_DEFAULT, &ab, enc, l1, lens, NR, dec, N);
    CHECK(rc == 0, "chain decode rc");
    CHECK(memcmp(qual, dec, N) == 0, "chain round-trips");

    size_t l2 = cap;
    rc = ttio_v6_chain_encode(&TTIO_V6_DEFAULT, &ab, qual, lens, NR, enc2, &l2);
    CHECK(rc == 0 && l2 == l1 && memcmp(enc, enc2, l1) == 0,
          "second encode is byte-identical");

    /* Capacity: a buffer far too small must fail rather than overrun. */
    {
        uint8_t small[64];
        size_t  ls = sizeof small;
        rc = ttio_v6_chain_encode(&TTIO_V6_DEFAULT, &ab, qual, lens, NR, small,
                                  &ls);
        CHECK(rc != 0, "undersized output buffer is rejected");
    }

    /* Parameter validation. */
    {
        ttio_v6_param bad = { 12, 5, 4, 3, 2 };   /* Q+P+D = 18 */
        size_t        lb = cap;
        rc = ttio_v6_chain_encode(&bad, &ab, qual, lens, NR, enc, &lb);
        CHECK(rc != 0, "Q+P+D over 16 is rejected");

        ttio_v6_param bad_shift = { 8, 9, 4, 3, 2 };  /* qshift > 8 */
        lb = cap;
        rc = ttio_v6_chain_encode(&bad_shift, &ab, qual, lens, NR, enc, &lb);
        CHECK(rc != 0, "qshift over 8 is rejected");
    }

    /* A single read, and a one-symbol read. */
    {
        uint32_t one = LEN;
        size_t   lo = cap;
        rc = ttio_v6_chain_encode(&TTIO_V6_DEFAULT, &ab, qual, &one, 1, enc, &lo);
        CHECK(rc == 0, "single-read encode rc");
        rc = ttio_v6_chain_decode(&TTIO_V6_DEFAULT, &ab, enc, lo, &one, 1, dec,
                                  LEN);
        CHECK(rc == 0 && memcmp(qual, dec, LEN) == 0,
              "single read round-trips");

        uint32_t tiny = 1;
        lo = cap;
        rc = ttio_v6_chain_encode(&TTIO_V6_DEFAULT, &ab, qual, &tiny, 1, enc, &lo);
        CHECK(rc == 0, "one-symbol encode rc");
        rc = ttio_v6_chain_decode(&TTIO_V6_DEFAULT, &ab, enc, lo, &tiny, 1, dec, 1);
        CHECK(rc == 0 && dec[0] == qual[0], "one symbol round-trips");
    }

    free(qual); free(seq); free(lens); free(enc); free(enc2); free(dec);
    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
