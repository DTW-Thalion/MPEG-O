/* native/tests/test_engine_api.c
 *
 * The engine abstraction: the CPU engine's identity and slot protocol,
 * and the property everything else rests on, that routing a block
 * through an engine does not change the bytes it produces.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/ttio_rans.h"
#include "../src/m94z_v6.h"
#include "../src/ttio_engine.h"

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
    uint64_t s = 42;
    size_t   k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        lens[r] = len;
        for (uint32_t i = 0; i < len; i++, k++) {
            unsigned bi = (unsigned)(xs(&s) % 4);
            qual[k] = (uint8_t)(40 + 10 * bi + (xs(&s) % 4));
        }
    }
}

int main(void) {
    const ttio_engine *cpu = ttio_engine_cpu();
    CHECK(cpu != NULL, "cpu engine exists");
    CHECK(cpu != NULL && strcmp(cpu->name, "cpu") == 0,
          "cpu engine is named cpu");
    CHECK(cpu != NULL && cpu->slots() >= 1,
          "cpu engine has at least one slot");
    CHECK(cpu != NULL && cpu->try_acquire() == 1,
          "cpu engine always grants a slot");
    if (cpu) cpu->release();
    CHECK(strcmp(ttio_engine_active_name(), "cpu") == 0,
          "active engine is cpu");

    enum { NR = 2000, LEN = 100, N = NR * LEN };
    uint8_t  *qual = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    make_corpus(qual, lens, NR, LEN);

    size_t   cap = (size_t)N + (1 << 20);
    uint8_t *a = malloc(cap), *b = malloc(cap);
    size_t   la = cap, lb = cap;

    int rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, a, &la);
    CHECK(rc == 0, "encode rc through the engine path");
    rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                             TTIO_V6_DEFAULT_SEG_SYMBOLS, 1, b, &lb);
    CHECK(rc == 0, "single-threaded encode rc");
    CHECK(la == lb && memcmp(a, b, la) == 0,
          "engine output is independent of thread count");

    /* The job the engine receives must round-trip through the decoder
     * exactly as before the refactor. */
    {
        uint8_t  *back = malloc(N);
        uint32_t *rl = malloc(NR * sizeof(*rl));
        rc = ttio_m94z_v6_decode(a, la, rl, NR, 4, back, N);
        CHECK(rc == 0 && memcmp(qual, back, N) == 0,
              "engine-encoded block still round-trips");
        free(back);
        free(rl);
    }

    free(qual); free(lens); free(a); free(b);
    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
