/* native/tests/test_m94z_qual_umbrella.c
 *
 * Umbrella qualities encode/decode: exact-size strategy pick across
 * V4 presets + S5/S6, version dispatch, the sequences gate, and the
 * size floor.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../include/ttio_rans.h"
#include "../src/fqzcomp_seqctx.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

static uint64_t xs(uint64_t *s) {
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}

/* Quality is a function of the CURRENT base plus 2 bits of noise, and
 * bases are i.i.d., so quality history and position carry nothing the
 * V4 contexts can use while the sequence window recovers ~2 bits per
 * quality. This is the shape sequence context exists for. */
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
    /* Large corpus: above TTIO_M94Z_V5_MIN_QUALITIES (1 MiB). */
    enum { NR = 11000, LEN = 100, N = NR * LEN };
    uint8_t *qual = malloc(N), *seq = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    make_corpus(qual, seq, lens, NR, LEN);
    uint8_t *flags = calloc(NR, 1);

    size_t cap = N + (1 << 20);
    uint8_t *o_seq = malloc(cap), *o_noseq = malloc(cap), *o_v4 = malloc(cap);
    size_t l_seq = cap, l_noseq = cap, l_v4 = cap;

    /* 1: auto + seq -> version 5, smaller than the no-seq stream. */
    int rc = ttio_m94z_qual_encode(qual, N, lens, NR, flags, seq,
                                   -1, 0, o_seq, &l_seq);
    CHECK(rc == 0, "auto+seq encode rc");
    CHECK(o_seq[4] == 5, "auto+seq emits version 5");

    rc = ttio_m94z_qual_encode(qual, N, lens, NR, flags, NULL,
                               -1, 0, o_noseq, &l_noseq);
    CHECK(rc == 0, "auto no-seq encode rc");
    CHECK(l_seq < l_noseq, "version 5 is smaller on the motif corpus");

    /* 2: no-seq stream is byte-identical to direct V4 encode. */
    rc = ttio_m94z_v4_encode(qual, N, lens, NR, flags, -1, 0,
                             o_v4, &l_v4);
    CHECK(rc == 0, "direct v4 encode rc");
    CHECK(o_noseq[4] == 4, "no-seq emits version 4");
    CHECK(l_noseq == l_v4 && memcmp(o_noseq, o_v4, l_v4) == 0,
          "no-seq umbrella bytes identical to direct V4");

    /* 3: flat qualities -> V4 wins even with sequences present. */
    {
        uint8_t *qf = malloc(N);
        memset(qf, 70, N);
        size_t lf = cap;
        rc = ttio_m94z_qual_encode(qf, N, lens, NR, flags, seq,
                                   -1, 0, o_v4, &lf);
        CHECK(rc == 0 && o_v4[4] == 4, "flat qualities stay version 4");
        free(qf);
    }

    /* 4: below the size floor -> version 4 despite sequences. */
    {
        enum { NRS = 300, NS = NRS * 100 };
        size_t ls = cap;
        rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, seq,
                                   -1, 0, o_v4, &ls);
        CHECK(rc == 0 && o_v4[4] == 4, "below floor stays version 4");

        /* 5: forced S5 on the small corpus -> version 5, round-trips,
         * read_lengths recovered from the RLT. */
        ls = cap;
        rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, seq,
                                   5, 0, o_v4, &ls);
        CHECK(rc == 0 && o_v4[4] == 5, "forced S5 emits version 5");
        uint8_t *back = malloc(NS);
        uint32_t *back_lens = calloc(NRS, sizeof(uint32_t));
        rc = ttio_m94z_qual_decode(o_v4, ls, back_lens, NRS, flags, seq,
                                   back, NS);
        CHECK(rc == 0 && memcmp(back, qual, NS) == 0,
              "forced S5 round trips");
        CHECK(memcmp(back_lens, lens, NRS * sizeof(uint32_t)) == 0,
              "read_lengths recovered from RLT");

        /* 6: forced S5 without sequences errors. */
        ls = cap;
        rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, NULL,
                                   5, 0, o_v4, &ls);
        CHECK(rc == TTIO_SEQCTX_ERR_NO_SEQ, "forced S5 without seq errors");

        /* 7: V5 decode without sequences / with bad length. */
        ls = cap;
        rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, seq,
                                   5, 0, o_v4, &ls);
        CHECK(rc == 0, "re-encode for decode-gate checks");
        rc = ttio_m94z_qual_decode(o_v4, ls, back_lens, NRS, flags, NULL,
                                   back, NS);
        CHECK(rc == TTIO_SEQCTX_ERR_NO_SEQ, "V5 decode without seq errors");
        rc = ttio_m94z_qual_decode(o_v4, ls, back_lens, NRS, flags, seq,
                                   back, NS - 1);
        CHECK(rc == TTIO_SEQCTX_ERR_ARGS, "V5 decode length mismatch errors");

        /* 8: flags bit 1 cleared by hand -> corrupt. */
        {
            uint8_t saved = o_v4[5];
            o_v4[5] = (uint8_t)(saved & ~0x02u);
            rc = ttio_m94z_qual_decode(o_v4, ls, back_lens, NRS, flags,
                                       seq, back, NS);
            CHECK(rc != 0, "cleared has_seqctx_body flag rejected");
            o_v4[5] = saved;
        }
        free(back); free(back_lens);
    }

    /* 9: V4 stream through the umbrella decode round-trips. */
    {
        uint8_t *back = malloc(N);
        uint32_t *back_lens = calloc(NR, sizeof(uint32_t));
        rc = ttio_m94z_qual_decode(o_noseq, l_noseq, back_lens, NR, flags,
                                   NULL, back, N);
        CHECK(rc == 0 && memcmp(back, qual, N) == 0,
              "V4 stream round trips through umbrella");
        free(back); free(back_lens);
    }

    /* 10: hint 7 == V4 with internal preset selection, sequences
     * present: byte-identical to the no-seq auto stream. */
    {
        size_t l7 = cap;
        rc = ttio_m94z_qual_encode(qual, N, lens, NR, flags, seq,
                                   TTIO_M94Z_HINT_V4_AUTO, 0, o_v4, &l7);
        CHECK(rc == 0, "hint 7 encode rc");
        CHECK(l7 == l_noseq && memcmp(o_v4, o_noseq, l_noseq) == 0,
              "hint 7 bytes identical to V4-auto");
    }

    /* 11: stream strategy sniffer. */
    {
        CHECK(ttio_m94z_qual_stream_strategy(o_noseq, l_noseq) == 4,
              "sniffer reads V4");
        int w = ttio_m94z_qual_stream_strategy(o_seq, l_seq);
        CHECK(w == 5 || w == 6, "sniffer reads auto V5 winner");
        enum { NRS2 = 300, NS2 = NRS2 * 100 };
        size_t l5 = cap, l6 = cap;
        rc = ttio_m94z_qual_encode(qual, NS2, lens, NRS2, flags, seq,
                                   5, 0, o_v4, &l5);
        CHECK(rc == 0 && ttio_m94z_qual_stream_strategy(o_v4, l5) == 5,
              "sniffer reads S5");
        rc = ttio_m94z_qual_encode(qual, NS2, lens, NRS2, flags, seq,
                                   6, 0, o_v4, &l6);
        CHECK(rc == 0 && ttio_m94z_qual_stream_strategy(o_v4, l6) == 6,
              "sniffer reads S6");
        CHECK(ttio_m94z_qual_stream_strategy(NULL, 0) < 0,
              "sniffer rejects NULL");
        CHECK(ttio_m94z_qual_stream_strategy(o_noseq, 8) < 0,
              "sniffer rejects short input");
        {
            uint8_t junk[30];
            memset(junk, 0x58, sizeof junk);
            CHECK(ttio_m94z_qual_stream_strategy(junk, sizeof junk) < 0,
                  "sniffer rejects junk");
        }
    }

    /* 12: hint 8 forces V6, which needs no sequences either way. */
    {
        uint8_t  *o_v6 = malloc(cap);
        uint8_t  *back = malloc(N);
        uint32_t *rl = malloc(NR * sizeof(*rl));
        size_t    l_v6 = cap;

        rc = ttio_m94z_qual_encode(qual, N, lens, NR, flags, NULL,
                                   TTIO_M94Z_HINT_V6, 0, o_v6, &l_v6);
        CHECK(rc == 0, "hint 8 encode rc");
        CHECK(o_v6[4] == 6, "hint 8 emits version 6");
        CHECK(ttio_m94z_qual_stream_strategy(o_v6, l_v6) == 8,
              "sniffer reads V6");

        rc = ttio_m94z_qual_decode(o_v6, l_v6, rl, NR, flags, NULL, back, N);
        CHECK(rc == 0 && memcmp(qual, back, N) == 0,
              "V6 round-trips without sequences");

        /* Passing sequences must not change the V6 stream. */
        {
            size_t   l_v6s = cap;
            uint8_t *o_v6s = malloc(cap);
            rc = ttio_m94z_qual_encode(qual, N, lens, NR, flags, seq,
                                       TTIO_M94Z_HINT_V6, 0, o_v6s, &l_v6s);
            CHECK(rc == 0 && l_v6s == l_v6 && memcmp(o_v6s, o_v6, l_v6) == 0,
                  "hint 8 ignores sequences");
            free(o_v6s);
        }

        CHECK(ttio_m94z_qual_stream_strategy(o_v6, 31) < 0,
              "sniffer rejects a truncated V6 stream");

        free(o_v6); free(back); free(rl);
    }

    /* 13: auto-tune never reaches V6. */
    CHECK(o_seq[4] == 5 && o_noseq[4] == 4,
          "auto picks V4 or V5, never V6");

    printf("%s: %d failures\n", __FILE__, failures);
    free(qual); free(seq); free(lens); free(flags);
    free(o_seq); free(o_noseq); free(o_v4);
    return failures ? 1 : 0;
}
