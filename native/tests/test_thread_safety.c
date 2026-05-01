/*
 * test_thread_safety.c — Thread-safety tests for the libttio_rans
 * pthread thread pool (Task 13).
 *
 * Two scenarios:
 *
 * 1. Concurrent encode/decode: spawn N=8 threads, each encodes and
 *    decodes its own private input on its own private buffers.
 *    The threads share nothing except the rANS library (kernel
 *    function pointers, dispatch state).  This catches races in any
 *    shared state inside libttio_rans, not in the pool itself.
 *
 * 2. Submit/wait stress: a single thread submits MANY small tasks to
 *    one shared ttio_rans_pool, then waits via pool_destroy.  Each
 *    task atomically increments a counter.  We assert the final
 *    counter equals the number of submits.  This exercises the pool
 *    queue, mutex, and condvars under burst load.
 *
 * Both tests use only the public API + the per-platform <pthread.h>
 * for spawning the test driver threads.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"

/* Internal API: pool_submit/wait — declared here directly so the test
 * does not depend on libttio_rans's private rans_internal.h. */
extern int  _ttio_rans_pool_submit(ttio_rans_pool *pool,
                                   void (*fn)(void *), void *arg);
extern void _ttio_rans_pool_wait(ttio_rans_pool *pool);
extern int  _ttio_rans_pool_n_threads(const ttio_rans_pool *pool);

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ── helpers ───────────────────────────────────────────────────────── */

static void build_cum(uint16_t n_ctx,
                      const uint32_t (*freq)[256],
                      uint32_t (*cum)[256])
{
    for (uint16_t ctx = 0; ctx < n_ctx; ctx++) {
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) {
            cum[ctx][s] = running;
            running += freq[ctx][s];
        }
    }
}

static int do_roundtrip(const uint8_t *syms,
                        const uint16_t *ctxs,
                        size_t n,
                        uint16_t n_ctx,
                        const uint32_t (*freq)[256])
{
    uint32_t (*cum)[256] = (uint32_t (*)[256])
        calloc(n_ctx, 256 * sizeof(uint32_t));
    if (!cum) return 1;
    build_cum(n_ctx, freq, cum);

    uint8_t (*dtab)[TTIO_RANS_T] = (uint8_t (*)[TTIO_RANS_T])
        calloc(n_ctx, TTIO_RANS_T);
    if (!dtab) { free(cum); return 1; }

    if (ttio_rans_build_decode_table(n_ctx, freq,
                                     (const uint32_t (*)[256])cum,
                                     dtab) != TTIO_RANS_OK) {
        free(cum); free(dtab); return 1;
    }

    size_t enc_cap = 64 + n * 4 + 256;
    uint8_t *enc = (uint8_t *)malloc(enc_cap);
    if (!enc) { free(cum); free(dtab); return 1; }
    size_t enc_len = enc_cap;

    if (ttio_rans_encode_block(syms, ctxs, n, n_ctx, freq,
                               enc, &enc_len) != TTIO_RANS_OK) {
        free(enc); free(cum); free(dtab); return 1;
    }

    uint8_t *dec = (uint8_t *)calloc(n ? n : 1, 1);
    if (!dec) { free(enc); free(cum); free(dtab); return 1; }

    if (ttio_rans_decode_block(enc, enc_len, ctxs, n_ctx, freq,
                               (const uint32_t (*)[256])cum,
                               (const uint8_t (*)[TTIO_RANS_T])dtab,
                               dec, n) != TTIO_RANS_OK) {
        free(dec); free(enc); free(cum); free(dtab); return 1;
    }

    int mismatch = 0;
    for (size_t i = 0; i < n; i++) {
        if (dec[i] != syms[i]) { mismatch = 1; break; }
    }
    free(dec); free(enc); free(cum); free(dtab);
    return mismatch;
}

/* ── test 1: concurrent encode/decode ──────────────────────────────── */

#define N_DRIVER_THREADS 8
#define DRIVER_N_SYMS    1024

typedef struct {
    int         tid;
    uint32_t    seed;
    int         result; /* 0=ok, 1=fail */
} driver_args;

static void *driver_thread(void *arg)
{
    driver_args *a = (driver_args *)arg;
    size_t n = DRIVER_N_SYMS;
    uint8_t  *s = (uint8_t  *)malloc(n);
    uint16_t *c = (uint16_t *)calloc(n, sizeof(uint16_t));
    if (!s || !c) { a->result = 1; free(s); free(c); return NULL; }

    /* Distinct deterministic input per thread. */
    uint32_t rng = a->seed;
    for (size_t i = 0; i < n; i++) {
        rng = rng * 1103515245u + 12345u;
        s[i] = (uint8_t)((rng >> 16) & 7);
        c[i] = 0;
    }

    uint32_t f[1][256]; memset(f, 0, sizeof(f));
    /* A skewed distribution that exercises non-trivial freq scaling. */
    f[0][0]=1024; f[0][1]=768; f[0][2]=640; f[0][3]=512;
    f[0][4]=384;  f[0][5]=320; f[0][6]=256; f[0][7]=192;

    /* Run several round-trips per thread to amplify race detection. */
    int fail = 0;
    for (int rep = 0; rep < 16; rep++) {
        if (do_roundtrip(s, c, n, 1,
                         (const uint32_t (*)[256])f) != 0) {
            fail = 1; break;
        }
    }
    free(s); free(c);
    a->result = fail;
    return NULL;
}

static void test_concurrent_encode_decode(void)
{
    /* Pool is shared across the spawned driver threads.  The drivers
     * use the round-trip helper directly (which calls the rANS encode
     * / decode block functions, NOT pool_submit).  The pool's
     * presence in this test is incidental — the goal is to verify the
     * dispatch / kernel path is reentrant under concurrency. */
    ttio_rans_pool *pool = ttio_rans_pool_create(N_DRIVER_THREADS);
    assert(pool != NULL);

    pthread_t threads[N_DRIVER_THREADS];
    driver_args args[N_DRIVER_THREADS];
    for (int i = 0; i < N_DRIVER_THREADS; i++) {
        args[i].tid = i;
        args[i].seed = 0xDEAD0000u + (uint32_t)i;
        args[i].result = 1; /* default to failure */
        int rc = pthread_create(&threads[i], NULL, driver_thread, &args[i]);
        assert(rc == 0);
    }
    for (int i = 0; i < N_DRIVER_THREADS; i++) {
        pthread_join(threads[i], NULL);
    }
    int any_fail = 0;
    for (int i = 0; i < N_DRIVER_THREADS; i++) {
        if (args[i].result != 0) {
            fprintf(stderr, "  thread %d round-trip failed\n", i);
            any_fail = 1;
        }
    }
    assert(any_fail == 0);

    ttio_rans_pool_destroy(pool);
    printf("  test_concurrent_encode_decode: PASS (%d threads)\n",
           N_DRIVER_THREADS);
}

/* ── test 2: submit/wait stress ────────────────────────────────────── */

static atomic_int g_counter;

static void increment_task(void *arg)
{
    (void)arg;
    atomic_fetch_add(&g_counter, 1);
}

static void test_submit_wait_stress(void)
{
    const int N_TASKS = 10000;
    ttio_rans_pool *pool = ttio_rans_pool_create(4);
    assert(pool != NULL);
    assert(_ttio_rans_pool_n_threads(pool) == 4);

    atomic_store(&g_counter, 0);
    for (int i = 0; i < N_TASKS; i++) {
        int rc = _ttio_rans_pool_submit(pool, increment_task, NULL);
        assert(rc == TTIO_RANS_OK);
    }
    _ttio_rans_pool_wait(pool);

    int got = atomic_load(&g_counter);
    if (got != N_TASKS) {
        fprintf(stderr, "  expected %d, got %d\n", N_TASKS, got);
    }
    assert(got == N_TASKS);

    /* Submit a second batch *after* wait() to verify the pool still
     * functions (no permanent stopping flag was set). */
    atomic_store(&g_counter, 0);
    for (int i = 0; i < 100; i++) {
        int rc = _ttio_rans_pool_submit(pool, increment_task, NULL);
        assert(rc == TTIO_RANS_OK);
    }
    _ttio_rans_pool_wait(pool);
    assert(atomic_load(&g_counter) == 100);

    ttio_rans_pool_destroy(pool);
    printf("  test_submit_wait_stress: PASS (%d tasks)\n", N_TASKS);
}

/* ── test 3: pool with default thread count ────────────────────────── */

static void test_pool_default_threads(void)
{
    ttio_rans_pool *pool = ttio_rans_pool_create(0);
    assert(pool != NULL);
    int n = _ttio_rans_pool_n_threads(pool);
    assert(n >= 1);
    /* Sanity: defaulting from sysconf yields at least 1, usually >1. */
    ttio_rans_pool_destroy(pool);
    printf("  test_pool_default_threads: PASS (n=%d)\n", n);
}

/* ── test 4: empty destroy ────────────────────────────────────────── */

static void test_pool_empty_destroy(void)
{
    /* Create + destroy with no submissions: must not deadlock or leak. */
    ttio_rans_pool *pool = ttio_rans_pool_create(2);
    assert(pool != NULL);
    ttio_rans_pool_destroy(pool);
    printf("  test_pool_empty_destroy: PASS\n");
}

/* ── test 5: destroy without explicit wait ─────────────────────────── */

static void test_pool_destroy_drains(void)
{
    /* pool_destroy must wait for in-flight + queued tasks to complete
     * before joining workers.  Submit a batch, then destroy without
     * an explicit wait. */
    ttio_rans_pool *pool = ttio_rans_pool_create(4);
    assert(pool != NULL);
    atomic_store(&g_counter, 0);
    const int N = 1000;
    for (int i = 0; i < N; i++) {
        int rc = _ttio_rans_pool_submit(pool, increment_task, NULL);
        assert(rc == TTIO_RANS_OK);
    }
    ttio_rans_pool_destroy(pool); /* no explicit wait */
    int got = atomic_load(&g_counter);
    if (got != N)
        fprintf(stderr, "  destroy_drains: expected %d, got %d\n", N, got);
    assert(got == N);
    printf("  test_pool_destroy_drains: PASS\n");
}

/* ── main ──────────────────────────────────────────────────────────── */

int main(void)
{
    printf("ttio_rans thread-safety tests:\n");
    printf("  selected kernel: %s\n", ttio_rans_kernel_name());

    test_pool_empty_destroy();
    test_pool_default_threads();
    test_submit_wait_stress();
    test_pool_destroy_drains();
    test_concurrent_encode_decode();

    printf("All thread-safety tests passed.\n");
    return 0;
}
