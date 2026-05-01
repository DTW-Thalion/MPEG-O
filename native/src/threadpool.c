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
 * Task 14: dispatch to the V2 multi-block wire-format implementation
 * defined in wire_format.c.
 *
 * encode_mt always writes V2.  decode_mt reads the version byte and
 * dispatches to V1 or V2; V1 is the single-block fallback for streams
 * produced by libttio_rans's own ttio_rans_encode_mt during Task 13
 * (and any future caller that constructs a V1 stream by hand).
 *
 * V1 compatibility in this C library handles streams produced by
 * libttio_rans's own ttio_rans_encode_block.  Streams produced by
 * the Cython implementation use a different lane layout and must be
 * decoded by the Cython path in Python (see fqzcomp_nx16_z.py
 * three-tier dispatch).
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
    return ttio_rans_encode_mt_v2(pool, symbols, contexts, n_symbols,
                                  n_contexts, reads_per_block,
                                  read_lengths, n_reads, out, out_len);
}

int ttio_rans_decode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols)
{
    if (!compressed || !n_symbols) return TTIO_RANS_ERR_PARAM;
    if (comp_len < 5) return TTIO_RANS_ERR_CORRUPT;
    /* magic check */
    if (compressed[0] != 'M' || compressed[1] != '9' ||
        compressed[2] != '4' || compressed[3] != 'Z')
        return TTIO_RANS_ERR_CORRUPT;
    uint8_t version = compressed[4];
    if (version == 1) {
        return ttio_rans_decode_mt_v1(compressed, comp_len, symbols, n_symbols);
    } else if (version == 2) {
        return ttio_rans_decode_mt_v2(pool, compressed, comp_len,
                                      symbols, n_symbols);
    }
    return TTIO_RANS_ERR_CORRUPT;
}
