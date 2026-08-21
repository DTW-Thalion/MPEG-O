/* native/tests/test_m94z_v6_block.c
 *
 * V6 segmented block coder: byte determinism across thread counts,
 * parallel round-trip, container version, degenerate blocks, and
 * rejection of a read-length table that does not match the stream.
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

static void make_corpus(uint8_t *qual, uint32_t *lens, size_t n_reads,
                        uint32_t len) {
    static const uint8_t B[4] = {'A','C','G','T'};
    uint64_t s = 42;
    size_t   k = 0;
    (void)B;
    for (size_t r = 0; r < n_reads; r++) {
        lens[r] = len;
        for (uint32_t i = 0; i < len; i++, k++) {
            unsigned bi = (unsigned)(xs(&s) % 4);
            qual[k] = (uint8_t)(40 + 10 * bi + (xs(&s) % 4));
        }
    }
}

int main(void) {
    /* 3 MB at the provisional 256 Ki segment target is about 12
     * segments, so threads have real work to divide. */
    enum { NR = 30000, LEN = 100, N = NR * LEN };
    uint8_t  *qual = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    make_corpus(qual, lens, NR, LEN);

    size_t   cap = (size_t)N + (1 << 20);
    uint8_t *e1 = malloc(cap), *e8 = malloc(cap);
    uint8_t *d1 = malloc(N), *d8 = malloc(N);
    uint32_t *rl1 = malloc(NR * sizeof(*rl1));
    uint32_t *rl8 = malloc(NR * sizeof(*rl8));

    size_t l1 = cap, l8 = cap;
    int rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 1, e1, &l1);
    CHECK(rc == 0, "encode threads=1 rc");
    rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                             TTIO_V6_DEFAULT_SEG_SYMBOLS, 8, e8, &l8);
    CHECK(rc == 0, "encode threads=8 rc");
    CHECK(l1 == l8 && memcmp(e1, e8, l1) == 0,
          "bytes are independent of thread count");
    CHECK(e1[4] == 6, "container version byte is 6");
    CHECK(l1 < (size_t)N, "block output is smaller than input");

    rc = ttio_m94z_v6_decode(e1, l1, rl1, NR, 1, d1, N);
    CHECK(rc == 0, "decode threads=1 rc");
    CHECK(memcmp(qual, d1, N) == 0, "round-trips on one thread");
    CHECK(memcmp(lens, rl1, NR * sizeof(*lens)) == 0,
          "read lengths recovered");

    rc = ttio_m94z_v6_decode(e1, l1, rl8, NR, 8, d8, N);
    CHECK(rc == 0, "decode threads=8 rc");
    CHECK(memcmp(qual, d8, N) == 0, "round-trips on eight threads");

    /* A block whose reads are longer than the segment target: every
     * segment is one read, because segments hold whole reads. */
    {
        enum { BR = 4, BLEN = 300000, BN = BR * BLEN };
        uint8_t  *bq = malloc(BN);
        uint32_t *bl = malloc(BR * sizeof(*bl));
        make_corpus(bq, bl, BR, BLEN);
        size_t   bcap = (size_t)BN + (1 << 20), blen = bcap;
        uint8_t *be = malloc(bcap), *bd = malloc(BN);
        uint32_t *brl = malloc(BR * sizeof(*brl));
        rc = ttio_m94z_v6_encode(bq, BN, bl, BR, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, be, &blen);
        CHECK(rc == 0, "long-read encode rc");
        rc = ttio_m94z_v6_decode(be, blen, brl, BR, 4, bd, BN);
        CHECK(rc == 0 && memcmp(bq, bd, BN) == 0,
              "reads longer than the segment target round-trip");
        free(bq); free(bl); free(be); free(bd); free(brl);
    }

    /* Degenerate blocks. */
    {
        uint8_t  one_q[1] = { 55 };
        uint32_t one_l[1] = { 1 };
        uint8_t  buf[4096], back[1];
        uint32_t back_l[1];
        size_t   bl2 = sizeof buf;
        rc = ttio_m94z_v6_encode(one_q, 1, one_l, 1, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, buf, &bl2);
        CHECK(rc == 0, "one-symbol block encode rc");
        rc = ttio_m94z_v6_decode(buf, bl2, back_l, 1, 4, back, 1);
        CHECK(rc == 0 && back[0] == 55, "one-symbol block round-trips");
    }

    /* A decoder told the wrong read count must not silently succeed. */
    {
        uint32_t *wrong = malloc(NR * sizeof(*wrong));
        uint8_t  *scratch = malloc(N);
        rc = ttio_m94z_v6_decode(e1, l1, wrong, NR - 1, 1, scratch, N);
        CHECK(rc != 0, "wrong read count is rejected");
        rc = ttio_m94z_v6_decode(e1, l1, wrong, NR, 1, scratch, N - 1);
        CHECK(rc != 0, "wrong quality count is rejected");
        free(wrong); free(scratch);
    }

    free(qual); free(lens); free(e1); free(e8);
    free(d1); free(d8); free(rl1); free(rl8);
    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
