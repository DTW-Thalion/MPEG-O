/* native/tests/test_engine_selection.c
 *
 * Which engine a block goes to, and what happens when the GPU one is
 * absent, refuses, or fails. The GPU engine is injectable here so the
 * selection and spill logic can be tested on machines with no GPU,
 * which is most of them.
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

static int stub_calls;

static int  stub_slots(void)       { return 2; }
static int  stub_try_acquire(void) { return 1; }
static void stub_release(void)     { }

static int stub_encode(ttio_v6_job *job) {
    stub_calls++;
    return ttio_v6_encode_job_cpu(job);
}

static const ttio_engine k_stub = {
    "stub", stub_slots, stub_try_acquire, stub_release, stub_encode
};

/* Grants every other slot, so one encode exercises both engines. */
static int refuse_toggle;
static int flaky_try_acquire(void) {
    refuse_toggle = !refuse_toggle;
    return refuse_toggle;
}

static const ttio_engine k_flaky = {
    "flaky", stub_slots, flaky_try_acquire, stub_release, stub_encode
};

/* Takes the slot and then fails, which must not reach the caller. */
static int failing_encode(ttio_v6_job *job) {
    (void)job;
    stub_calls++;
    return -1;
}

static const ttio_engine k_failing = {
    "failing", stub_slots, stub_try_acquire, stub_release, failing_encode
};

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
    unsetenv("TTIO_GPU");
    ttio_gpu_mode_reset();
    CHECK(ttio_gpu_mode_get() == TTIO_GPU_OFF, "default mode is off");
    CHECK(ttio_engine_gpu() == NULL, "no gpu engine when off");
    CHECK(ttio_engine_gpu_available() == 0, "availability is 0 when off");
    CHECK(strcmp(ttio_engine_active_name(), "cpu") == 0,
          "active engine is cpu when off");

    setenv("TTIO_GPU", "force", 1);
    ttio_gpu_mode_reset();
    CHECK(ttio_gpu_mode_get() == TTIO_GPU_FORCE, "force is parsed");

    setenv("TTIO_GPU", "nonsense", 1);
    ttio_gpu_mode_reset();
    CHECK(ttio_gpu_mode_get() == TTIO_GPU_OFF,
          "an unrecognised value is off, not an error");

    unsetenv("TTIO_GPU");
    ttio_gpu_mode_reset();

    ttio_engine_set_test_gpu(&k_stub);
    CHECK(ttio_engine_gpu() == &k_stub, "an injected engine is returned");
    CHECK(ttio_engine_gpu_available() == 1, "availability is 1 when injected");
    CHECK(strcmp(ttio_engine_active_name(), "stub") == 0,
          "active name follows the injected engine");
    ttio_engine_set_test_gpu(NULL);
    CHECK(ttio_engine_gpu() == NULL, "injection can be cleared");

    /* Routing: a block must produce the same bytes whichever engine
     * encodes it, and a GPU engine that refuses or fails must not be
     * visible in the output. */
    {
        enum { NR = 4000, LEN = 100, N = NR * LEN };
        uint8_t  *qual = malloc(N);
        uint32_t *lens = malloc(NR * sizeof(*lens));
        make_corpus(qual, lens, NR, LEN);

        size_t   cap = (size_t)N + (1 << 20);
        uint8_t *base = malloc(cap), *mixed = malloc(cap), *fb = malloc(cap);
        size_t   l_base = cap, l_mixed = cap, l_fb = cap;

        ttio_engine_set_test_gpu(NULL);
        int rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                                     TTIO_V6_DEFAULT_SEG_SYMBOLS, 4,
                                     base, &l_base);
        CHECK(rc == 0, "cpu-only reference encode rc");

        stub_calls = 0;
        ttio_engine_set_test_gpu(&k_stub);
        rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 4,
                                 mixed, &l_mixed);
        CHECK(rc == 0, "gpu-engine encode rc");
        CHECK(stub_calls > 0, "the gpu engine was actually consulted");
        CHECK(l_mixed == l_base && memcmp(mixed, base, l_base) == 0,
              "gpu-engine output equals cpu output");

        refuse_toggle = 0;
        ttio_engine_set_test_gpu(&k_flaky);
        l_mixed = cap;
        rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 4,
                                 mixed, &l_mixed);
        CHECK(rc == 0 && l_mixed == l_base
              && memcmp(mixed, base, l_base) == 0,
              "spilling on a refused slot does not change the bytes");

        stub_calls = 0;
        ttio_engine_set_test_gpu(&k_failing);
        rc = ttio_m94z_v6_encode(qual, N, lens, NR, &TTIO_V6_DEFAULT,
                                 TTIO_V6_DEFAULT_SEG_SYMBOLS, 4, fb, &l_fb);
        CHECK(rc == 0, "a failing gpu engine does not fail the encode");
        CHECK(stub_calls > 0, "the failing engine was consulted");
        CHECK(l_fb == l_base && memcmp(fb, base, l_base) == 0,
              "a failing gpu engine falls back to cpu output");

        ttio_engine_set_test_gpu(NULL);
        free(qual); free(lens); free(base); free(mixed); free(fb);
    }

    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
