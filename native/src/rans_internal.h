/*
 * rans_internal.h — Internal kernel declarations for runtime SIMD dispatch.
 *
 * The public entry points `ttio_rans_encode_block` / `ttio_rans_decode_block`
 * are defined in dispatch.c.  They forward to one of the kernels declared
 * here based on cpuid feature detection performed at library load time.
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#ifndef TTIO_RANS_INTERNAL_H
#define TTIO_RANS_INTERNAL_H

#include "ttio_rans.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*ttio_rans_encode_fn)(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len);

typedef int (*ttio_rans_decode_fn)(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols);

/* Scalar reference kernel — always available. */
int _ttio_rans_encode_block_scalar(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len);

int _ttio_rans_decode_block_scalar(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols);

#if defined(__x86_64__) || defined(_M_X64) || defined(__amd64__)
int _ttio_rans_encode_block_sse41(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len);

int _ttio_rans_decode_block_sse41(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols);

int _ttio_rans_encode_block_avx2(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len);

int _ttio_rans_decode_block_avx2(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols);
#endif /* x86_64 */

/* Diagnostic: name of the kernel currently selected by the dispatcher.
 * Returns one of "scalar", "sse4.1", "avx2".  Useful for tests. */
const char *ttio_rans_kernel_name(void);

/* ── Internal thread-pool task submission API ──────────────────────────
 *
 * These are not part of the public ABI.  They are used by
 * ttio_rans_encode_mt / ttio_rans_decode_mt (and tests) to dispatch
 * parallel work to the pool created by ttio_rans_pool_create().
 *
 * Submit:  enqueues a task.  Returns 0 on success, non-zero on failure.
 * Wait:    blocks until the queue is empty AND no workers are running
 *          a task.  Subsequent submits after wait() returns are fine.
 */
int  _ttio_rans_pool_submit(ttio_rans_pool *pool,
                            void (*fn)(void *), void *arg);
void _ttio_rans_pool_wait(ttio_rans_pool *pool);

/* Number of worker threads in the pool (read-only, set at create time). */
int  _ttio_rans_pool_n_threads(const ttio_rans_pool *pool);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_RANS_INTERNAL_H */
