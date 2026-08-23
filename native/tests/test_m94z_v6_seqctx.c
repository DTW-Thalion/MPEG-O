/* native/tests/test_m94z_v6_seqctx.c
 *
 * V6's optional sequence-context field: round-trip at each width, the
 * body header carrying the width so a decoder needs no help, refusal to
 * code without sequences when the width is non-zero, backward
 * compatibility of width 0, and the automatic width choice.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/m94z_v6.h"
#include "../src/fqzcomp_seqctx.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

static uint64_t xs(uint64_t *s) {
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}

/* Qualities correlated with the base, so the sequence field has
 * something to find; without a correlation the width choice would be
 * measuring noise. */
static void make_corpus(uint8_t *qual, uint8_t *seq, uint32_t *lens,
                        size_t n_reads, uint32_t len) {
    static const uint8_t B[4] = { 'A', 'C', 'G', 'T' };
    uint64_t s = 7;
    size_t   k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        lens[r] = len;
        for (uint32_t i = 0; i < len; i++, k++) {
            unsigned bi = (unsigned)(xs(&s) % 4);
            seq[k] = B[bi];
            qual[k] = (uint8_t)(20 + 6 * bi + (xs(&s) % 3));
        }
    }
}

int main(void) {
    enum { NR = 20000, LEN = 100, N = NR * LEN };
    uint8_t  *qual = malloc(N), *seq = malloc(N), *back = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    uint32_t *rl = malloc(NR * sizeof(*rl));
    size_t    cap = (size_t)N + (1 << 20);
    uint8_t  *enc = malloc(cap);
    size_t    len0 = 0, len4 = 0, lenauto = 0;

    if (!qual || !seq || !back || !lens || !rl || !enc) return 77;
    make_corpus(qual, seq, lens, NR, LEN);

    /* Round-trip at each width, and the width reaches the decoder
     * through the body header rather than through the caller. */
    for (unsigned sb = 0; sb <= 4; sb += 2) {
        ttio_v6_param pm = TTIO_V6_DEFAULT;
        size_t l = cap;
        char   name[64];
        int    rc;
        pm.sbits = (uint8_t)sb;
        rc = ttio_m94z_v6_encode_seq(qual, seq, N, lens, NR, &pm,
                                     TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, enc, &l);
        snprintf(name, sizeof name, "sbits %u encodes", sb);
        CHECK(rc == 0, name);
        if (rc != 0) continue;
        if (sb == 0) len0 = l;
        if (sb == 4) len4 = l;

        memset(back, 0, N);
        rc = ttio_m94z_v6_decode_seq(enc, l, seq, rl, NR, 4, back, N);
        snprintf(name, sizeof name, "sbits %u round-trips", sb);
        CHECK(rc == 0 && memcmp(back, qual, N) == 0, name);
    }

    /* Width 0 is what every stream written before the field carried,
     * so it must still decode with no sequences at all. */
    {
        ttio_v6_param pm = TTIO_V6_DEFAULT;
        size_t l = cap;
        int    rc = ttio_m94z_v6_encode(qual, N, lens, NR, &pm,
                                        TTIO_V6_DEFAULT_SEG_SYMBOLS, 4,
                                        enc, &l);
        CHECK(rc == 0 && l == len0, "sbits 0 matches the sequence-less entry");
        memset(back, 0, N);
        rc = ttio_m94z_v6_decode(enc, l, rl, NR, 4, back, N);
        CHECK(rc == 0 && memcmp(back, qual, N) == 0,
              "sbits 0 decodes with no sequences");
    }

    /* A width above 0 cannot be coded without the bases it names. */
    {
        ttio_v6_param pm = TTIO_V6_DEFAULT;
        size_t l = cap;
        pm.sbits = 4;
        CHECK(ttio_m94z_v6_encode_seq(qual, NULL, N, lens, NR, &pm,
                                      TTIO_V6_DEFAULT_SEG_SYMBOLS, 4,
                                      enc, &l) == TTIO_SEQCTX_ERR_NO_SEQ,
              "sbits 4 without sequences is refused at encode");
        l = cap;
        if (ttio_m94z_v6_encode_seq(qual, seq, N, lens, NR, &pm,
                                    TTIO_V6_DEFAULT_SEG_SYMBOLS, 4,
                                    enc, &l) == 0) {
            CHECK(ttio_m94z_v6_decode_seq(enc, l, NULL, rl, NR, 4, back, N)
                      == TTIO_SEQCTX_ERR_NO_SEQ,
                  "sbits 4 without sequences is refused at decode");
        }
    }

    /* The automatic width never does worse than no sequence field: the
     * probe includes 0 among its candidates, so a corpus the field does
     * not help falls back to it. */
    {
        ttio_v6_param pm = TTIO_V6_DEFAULT;
        size_t l = cap;
        int    rc;
        pm.sbits = (uint8_t)TTIO_V6_SBITS_AUTO;
        rc = ttio_m94z_v6_encode_seq(qual, seq, N, lens, NR, &pm,
                                     TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, enc, &l);
        lenauto = l;
        CHECK(rc == 0, "auto width encodes");
        CHECK(rc == 0 && lenauto <= len0, "auto width is no worse than sbits 0");
        memset(back, 0, N);
        CHECK(rc == 0
              && ttio_m94z_v6_decode_seq(enc, l, seq, rl, NR, 4, back, N) == 0
              && memcmp(back, qual, N) == 0, "auto width round-trips");
        /* On a corpus built to correlate, the field should be chosen. */
        CHECK(rc == 0 && lenauto <= len4 + len4 / 100,
              "auto width lands on the field where it pays");
    }

    /* Without sequences the automatic width resolves to 0 rather than
     * failing, since 0 is the only width it could code. */
    {
        ttio_v6_param pm = TTIO_V6_DEFAULT;
        size_t l = cap;
        int    rc;
        pm.sbits = (uint8_t)TTIO_V6_SBITS_AUTO;
        rc = ttio_m94z_v6_encode_seq(qual, NULL, N, lens, NR, &pm,
                                     TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, enc, &l);
        CHECK(rc == 0 && l == len0, "auto width without sequences gives sbits 0");
    }

    free(qual); free(seq); free(back); free(lens); free(rl); free(enc);
    printf(failures ? "FAILURES %d\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
