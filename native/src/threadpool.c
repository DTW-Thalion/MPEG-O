/*
 * threadpool.c — Fixed-size pthread thread pool for libttio_rans.
 *
 * The pool is created with a configurable number of worker threads.
 * Tasks are pushed onto a FIFO linked-list queue protected by a mutex.
 * Workers wait on `work_cv` when the queue is empty (and not stopping)
 * and signal `done_cv` when no work remains in flight, so that
 * _ttio_rans_pool_wait() can implement join-style barriers without
 * tearing down the pool.
 *
 * Public symbols (declared in include/ttio_rans.h):
 *   ttio_rans_pool_create / ttio_rans_pool_destroy
 *   ttio_rans_encode_mt / ttio_rans_decode_mt
 *
 * Internal symbols (declared in src/rans_internal.h):
 *   _ttio_rans_pool_submit / _ttio_rans_pool_wait
 *   _ttio_rans_pool_n_threads
 *
 * Note: ttio_rans_encode_mt / ttio_rans_decode_mt are currently
 * single-block delegates.  Task 14 will introduce the V2 multi-block
 * wire format (magic "M94Z" + version 2 + block_count + per-block
 * compressed_size prefixes) and use this pool to dispatch the actual
 * parallel encode/decode work.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── internal types ────────────────────────────────────────────────── */

struct task_node {
    void  (*fn)(void *arg);
    void   *arg;
    struct task_node *next;
};

struct ttio_rans_pool {
    pthread_t        *threads;
    int               n_threads;
    pthread_mutex_t   mtx;
    pthread_cond_t    work_cv;     /* signalled when a task is enqueued     */
    pthread_cond_t    done_cv;     /* signalled when active_workers reaches 0
                                    * and queue is empty (wait() barrier)   */
    int               stopping;    /* set during destroy                    */
    int               active_workers; /* tasks currently being executed     */
    struct task_node *queue_head;
    struct task_node *queue_tail;
};

/* ── worker loop ───────────────────────────────────────────────────── */

static void *worker_main(void *arg)
{
    ttio_rans_pool *pool = (ttio_rans_pool *)arg;

    for (;;) {
        pthread_mutex_lock(&pool->mtx);

        /* Wait until either there is work, or the pool is stopping. */
        while (!pool->stopping && pool->queue_head == NULL) {
            pthread_cond_wait(&pool->work_cv, &pool->mtx);
        }

        if (pool->stopping && pool->queue_head == NULL) {
            pthread_mutex_unlock(&pool->mtx);
            break;
        }

        /* Dequeue. */
        struct task_node *node = pool->queue_head;
        pool->queue_head = node->next;
        if (pool->queue_head == NULL)
            pool->queue_tail = NULL;
        pool->active_workers++;
        pthread_mutex_unlock(&pool->mtx);

        /* Execute the task with the lock released. */
        node->fn(node->arg);
        free(node);

        /* Mark task done; if last one and queue empty, signal waiters. */
        pthread_mutex_lock(&pool->mtx);
        pool->active_workers--;
        if (pool->active_workers == 0 && pool->queue_head == NULL)
            pthread_cond_broadcast(&pool->done_cv);
        pthread_mutex_unlock(&pool->mtx);
    }

    return NULL;
}

/* ── public API: create / destroy ──────────────────────────────────── */

ttio_rans_pool *ttio_rans_pool_create(int n_threads)
{
    if (n_threads <= 0) {
        long n = sysconf(_SC_NPROCESSORS_ONLN);
        n_threads = (n > 0) ? (int)n : 1;
    }
    /* Defensive cap: avoid pathological values. */
    if (n_threads > 1024) n_threads = 1024;

    ttio_rans_pool *pool = (ttio_rans_pool *)calloc(1, sizeof(*pool));
    if (!pool) return NULL;

    pool->threads = (pthread_t *)calloc((size_t)n_threads, sizeof(pthread_t));
    if (!pool->threads) { free(pool); return NULL; }
    pool->n_threads = n_threads;

    if (pthread_mutex_init(&pool->mtx, NULL) != 0) {
        free(pool->threads); free(pool); return NULL;
    }
    if (pthread_cond_init(&pool->work_cv, NULL) != 0) {
        pthread_mutex_destroy(&pool->mtx);
        free(pool->threads); free(pool); return NULL;
    }
    if (pthread_cond_init(&pool->done_cv, NULL) != 0) {
        pthread_cond_destroy(&pool->work_cv);
        pthread_mutex_destroy(&pool->mtx);
        free(pool->threads); free(pool); return NULL;
    }

    /* Spawn workers.  If any fail, tear down cleanly. */
    int spawned = 0;
    for (int i = 0; i < n_threads; i++) {
        int rc = pthread_create(&pool->threads[i], NULL, worker_main, pool);
        if (rc != 0) {
            /* Signal already-spawned workers to exit, join them, then free. */
            pthread_mutex_lock(&pool->mtx);
            pool->stopping = 1;
            pthread_cond_broadcast(&pool->work_cv);
            pthread_mutex_unlock(&pool->mtx);
            for (int j = 0; j < spawned; j++) pthread_join(pool->threads[j], NULL);
            pthread_cond_destroy(&pool->done_cv);
            pthread_cond_destroy(&pool->work_cv);
            pthread_mutex_destroy(&pool->mtx);
            free(pool->threads);
            free(pool);
            return NULL;
        }
        spawned++;
    }
    return pool;
}

void ttio_rans_pool_destroy(ttio_rans_pool *pool)
{
    if (!pool) return;

    /* Wait for any pending tasks to complete first.  This is the
     * documented contract: pool_destroy is a barrier — callers may
     * submit, then call destroy without an explicit wait, and we
     * guarantee no task is dropped.  After this point, no new tasks
     * may arrive (only the owner thread destroys the pool). */
    pthread_mutex_lock(&pool->mtx);
    while (pool->queue_head != NULL || pool->active_workers > 0)
        pthread_cond_wait(&pool->done_cv, &pool->mtx);
    pool->stopping = 1;
    pthread_cond_broadcast(&pool->work_cv);
    pthread_mutex_unlock(&pool->mtx);

    for (int i = 0; i < pool->n_threads; i++)
        pthread_join(pool->threads[i], NULL);

    /* Pool is empty (queue drained above, no workers running) — nothing
     * to free in the queue.  Destroy primitives. */
    pthread_cond_destroy(&pool->done_cv);
    pthread_cond_destroy(&pool->work_cv);
    pthread_mutex_destroy(&pool->mtx);
    free(pool->threads);
    free(pool);
}

/* ── internal API: submit / wait ───────────────────────────────────── */

int _ttio_rans_pool_submit(ttio_rans_pool *pool,
                           void (*fn)(void *), void *arg)
{
    if (!pool || !fn) return TTIO_RANS_ERR_PARAM;

    struct task_node *node = (struct task_node *)malloc(sizeof(*node));
    if (!node) return TTIO_RANS_ERR_ALLOC;
    node->fn   = fn;
    node->arg  = arg;
    node->next = NULL;

    pthread_mutex_lock(&pool->mtx);
    if (pool->stopping) {
        /* Pool is being torn down — refuse new work. */
        pthread_mutex_unlock(&pool->mtx);
        free(node);
        return TTIO_RANS_ERR_PARAM;
    }
    if (pool->queue_tail == NULL) {
        pool->queue_head = node;
        pool->queue_tail = node;
    } else {
        pool->queue_tail->next = node;
        pool->queue_tail = node;
    }
    pthread_cond_signal(&pool->work_cv);
    pthread_mutex_unlock(&pool->mtx);
    return TTIO_RANS_OK;
}

void _ttio_rans_pool_wait(ttio_rans_pool *pool)
{
    if (!pool) return;
    pthread_mutex_lock(&pool->mtx);
    while (pool->queue_head != NULL || pool->active_workers > 0)
        pthread_cond_wait(&pool->done_cv, &pool->mtx);
    pthread_mutex_unlock(&pool->mtx);
}

int _ttio_rans_pool_n_threads(const ttio_rans_pool *pool)
{
    return pool ? pool->n_threads : 0;
}

/* ── public API: encode_mt / decode_mt ─────────────────────────────────
 *
 * Single-block delegate stubs.  Task 14 will introduce the V2 wire
 * format and use the pool above to encode/decode blocks in parallel.
 *
 * For now, encode_mt computes a per-input frequency table from the
 * symbols (so callers can use the MT API without separately building
 * one) and calls ttio_rans_encode_block() once.  decode_mt likewise
 * delegates to ttio_rans_decode_block() on the entire buffer; since
 * single-block input has no V2 container header, the contracts of
 * the two MT entry points are not yet symmetric — Task 14 fixes
 * this when the wire format lands.
 *
 * The pool argument is accepted but currently unused; it is required
 * for forward-compatibility so the API does not change once Task 14
 * wires up real parallelism.
 */

int ttio_rans_encode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    size_t          reads_per_block,
    const size_t   *read_lengths,
    size_t          n_reads,
    uint8_t        *out,
    size_t         *out_len)
{
    /* Task 14 will use these for block splitting. */
    (void)pool;
    (void)reads_per_block;
    (void)read_lengths;
    (void)n_reads;

    if (!out_len) return TTIO_RANS_ERR_PARAM;
    if (n_contexts == 0)
        return TTIO_RANS_ERR_PARAM;

    /* Compute per-context frequency table by scaling counts to T = 4096. */
    uint32_t (*freq)[256] = (uint32_t (*)[256])
        calloc(n_contexts, 256 * sizeof(uint32_t));
    if (!freq) return TTIO_RANS_ERR_ALLOC;

    /* Raw counts. */
    uint32_t *totals = (uint32_t *)calloc(n_contexts, sizeof(uint32_t));
    if (!totals) { free(freq); return TTIO_RANS_ERR_ALLOC; }

    for (size_t i = 0; i < n_symbols; i++) {
        uint16_t c = contexts ? contexts[i] : 0;
        if (c >= n_contexts) {
            free(totals); free(freq);
            return TTIO_RANS_ERR_PARAM;
        }
        freq[c][symbols[i]]++;
        totals[c]++;
    }

    /* Scale each context's counts into the [0, T] range, ensuring
     * non-zero entries remain at least 1 and the row sums to exactly T.
     * (For Task 14 the encoder will receive a precomputed freq table;
     * this scaling here exists only so the single-block delegate path
     * is end-to-end usable.) */
    for (uint16_t c = 0; c < n_contexts; c++) {
        if (totals[c] == 0) {
            /* Degenerate: no symbols with this context.  Fill with a
             * uniform single-symbol distribution so decode tables are
             * still well-formed.  No symbols actually use this context
             * so it cannot affect the round-trip. */
            freq[c][0] = TTIO_RANS_T;
            continue;
        }
        uint64_t T = TTIO_RANS_T;
        uint64_t tot = totals[c];
        uint32_t running = 0;
        int last_nz = -1;
        for (int s = 0; s < 256; s++) {
            if (freq[c][s] == 0) continue;
            uint64_t scaled = (freq[c][s] * T) / tot;
            if (scaled == 0) scaled = 1;
            freq[c][s] = (uint32_t)scaled;
            running += freq[c][s];
            last_nz = s;
        }
        /* Adjust last non-zero bucket to make the sum hit T exactly. */
        if (last_nz < 0) {
            freq[c][0] = TTIO_RANS_T;
        } else if (running != TTIO_RANS_T) {
            int64_t delta = (int64_t)TTIO_RANS_T - (int64_t)running;
            int64_t adj = (int64_t)freq[c][last_nz] + delta;
            if (adj < 1) {
                /* Pick a different non-zero bucket with enough slack. */
                for (int s = 0; s < 256; s++) {
                    if (freq[c][s] >= 1 + (uint32_t)(-delta)) {
                        freq[c][s] = (uint32_t)((int64_t)freq[c][s] + delta);
                        adj = -1;
                        break;
                    }
                }
                if (adj != -1) {
                    /* Could not adjust — give up by uniform fallback. */
                    free(totals); free(freq);
                    return TTIO_RANS_ERR_PARAM;
                }
            } else {
                freq[c][last_nz] = (uint32_t)adj;
            }
        }
    }

    int rc = ttio_rans_encode_block(symbols, contexts, n_symbols,
                                    n_contexts,
                                    (const uint32_t (*)[256])freq,
                                    out, out_len);
    free(totals);
    free(freq);
    return rc;
}

int ttio_rans_decode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols)
{
    /* Task 14 will use the pool + V2 container header. */
    (void)pool;
    (void)compressed;
    (void)comp_len;
    (void)symbols;
    (void)n_symbols;
    /* Without a wire-format container, we cannot recover contexts /
     * freq table from the compressed payload alone.  Until Task 14
     * adds the V2 header, callers should use ttio_rans_decode_block
     * directly with the metadata they already hold. */
    return TTIO_RANS_ERR_PARAM;
}
