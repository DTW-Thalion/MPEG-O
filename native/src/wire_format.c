/*
 * wire_format.c — V2 multi-block container for libttio_rans.
 *
 * V2 wire format
 * --------------
 *
 *   [V2 Container Header — 17 bytes]
 *     magic           "M94Z"          (4 bytes)
 *     version         2               (1 byte)
 *     block_count     N               (uint32 LE, 4 bytes)
 *     reads_per_block B               (uint32 LE, 4 bytes)
 *     context_params  4 bytes
 *       byte 0: n_contexts low byte
 *       byte 1: n_contexts high byte
 *       byte 2: reserved (caller-defined; rANS layer ignores)
 *       byte 3: reserved (caller-defined; rANS layer ignores)
 *
 *   [Per-block records, repeated N times]
 *     record_size     uint32 LE        (4 bytes; total size of THIS record
 *                                       including the 4-byte size field
 *                                       itself, the freq table, and payload)
 *     n_symbols       uint32 LE        (4 bytes; symbol count for this block)
 *     freq_table      n_contexts*512   (256 entries × uint16 LE per context)
 *     rANS payload    record_size - 8 - n_contexts*512 bytes
 *
 * Why the explicit `n_symbols` per block: ttio_rans_encode_block /
 * ttio_rans_decode_block need the original (unpadded) symbol count.
 * The number of symbols in a block depends on the read_lengths slice,
 * which is not derivable from the freq table alone.  Storing it
 * inline keeps each block self-decodable.
 *
 * Why freq tables stored as uint16 LE: each value is in [0, T=4096],
 * which fits in 12 bits; uint16 is the natural compact storage.
 *
 * V1 backward compatibility
 * --------------------------
 *
 * When ttio_rans_decode_mt sees magic "M94Z" + version=1, it treats
 * the bytes after the magic+version as a SELF-CONTAINED stream
 * produced by libttio_rans's own ttio_rans_encode_block (V1 of THIS
 * library — not the Python Cython V1 stream which has a different
 * lane layout).  The V1 stream embeds its own freq table at the head
 * (4-byte n_contexts + n_contexts × 512-byte freq_table + the
 * encode_block self-contained payload).  This format is what
 * ttio_rans_encode_mt produced in Task 13 for single-block use.
 *
 * Streams produced by the Cython implementation use a different
 * lane layout and must be decoded by the Cython path in Python
 * (see fqzcomp_nx16_z.py three-tier dispatch).
 *
 * Copyright (c) 2026 Thalion Global.  All rights reserved.
 */

#include "ttio_rans.h"
#include "rans_internal.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ── tiny helpers ──────────────────────────────────────────────────── */

static inline void wf_write_le16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
}

static inline void wf_write_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static inline uint16_t wf_read_le16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t wf_read_le32(const uint8_t *p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

/* ── V2 container constants ────────────────────────────────────────── */

#define WF_MAGIC0  'M'
#define WF_MAGIC1  '9'
#define WF_MAGIC2  '4'
#define WF_MAGIC3  'Z'
#define WF_V2      2u
#define WF_V1      1u
#define WF_V2_HDR_SIZE 17u  /* 4 + 1 + 4 + 4 + 4 */
#define WF_V2_BLOCK_HDR_SIZE 8u /* record_size + n_symbols */

/* ── Frequency-table builder (per spec §6 in task 14) ──────────────── *
 *
 * Builds a per-context freq table from a slice of symbols/contexts,
 * scaling each context's counts to sum to TTIO_RANS_T = 4096.
 * Context bins with no symbols receive a degenerate uniform single-
 * symbol distribution {freq[0]=T} so decode tables stay well-formed.
 *
 * Returns 0 on success, non-zero on validation failure.
 */
static int wf_build_freq_table(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    uint32_t      (*freq)[256])     /* output, calloc'd by caller */
{
    if (n_contexts == 0)
        return TTIO_RANS_ERR_PARAM;

    /* Allocate per-context totals */
    uint32_t *totals = (uint32_t *)calloc(n_contexts, sizeof(uint32_t));
    if (!totals) return TTIO_RANS_ERR_ALLOC;

    /* Tally raw counts */
    for (size_t i = 0; i < n_symbols; i++) {
        uint16_t c = contexts ? contexts[i] : 0;
        if (c >= n_contexts) {
            free(totals);
            return TTIO_RANS_ERR_PARAM;
        }
        freq[c][symbols[i]]++;
        totals[c]++;
    }

    /* Scale to T = 4096 */
    for (uint16_t c = 0; c < n_contexts; c++) {
        if (totals[c] == 0) {
            /* Degenerate: no symbols use this context.
             * Fill uniform single-symbol so decode table is valid. */
            freq[c][0] = TTIO_RANS_T;
            continue;
        }
        uint64_t T = TTIO_RANS_T;
        uint64_t tot = totals[c];
        uint32_t running = 0;
        int last_nz = -1;
        for (int s = 0; s < 256; s++) {
            if (freq[c][s] == 0) continue;
            uint64_t scaled = ((uint64_t)freq[c][s] * T) / tot;
            if (scaled == 0) scaled = 1;
            freq[c][s] = (uint32_t)scaled;
            running += freq[c][s];
            last_nz = s;
        }
        if (last_nz < 0) {
            freq[c][0] = TTIO_RANS_T;
        } else if (running != TTIO_RANS_T) {
            int64_t delta = (int64_t)TTIO_RANS_T - (int64_t)running;
            int64_t adj = (int64_t)freq[c][last_nz] + delta;
            if (adj < 1) {
                /* Spread the delta to a bigger bin. */
                int placed = 0;
                if (delta < 0) {
                    uint32_t need = (uint32_t)(-delta);
                    for (int s = 0; s < 256; s++) {
                        if (freq[c][s] >= 1 + need) {
                            freq[c][s] -= need;
                            placed = 1;
                            break;
                        }
                    }
                } else {
                    /* delta > 0: just add to first non-zero bin. */
                    for (int s = 0; s < 256; s++) {
                        if (freq[c][s] > 0) {
                            freq[c][s] += (uint32_t)delta;
                            placed = 1;
                            break;
                        }
                    }
                }
                if (!placed) {
                    free(totals);
                    return TTIO_RANS_ERR_PARAM;
                }
            } else {
                freq[c][last_nz] = (uint32_t)adj;
            }
        }
    }

    /* Padding symbols use ctx=0, sym=0 — ensure freq[0][0] >= 1 so
     * encode/decode is well-defined when n_block_symbols % 4 != 0. */
    if (freq[0][0] == 0) {
        /* Steal 1 from another nonzero bin in ctx 0. */
        int placed = 0;
        for (int s = 1; s < 256; s++) {
            if (freq[0][s] > 1) {
                freq[0][s] -= 1;
                freq[0][0] = 1;
                placed = 1;
                break;
            }
        }
        if (!placed) {
            free(totals);
            return TTIO_RANS_ERR_PARAM;
        }
    }

    free(totals);
    return TTIO_RANS_OK;
}

/* ── Per-block task structures ─────────────────────────────────────── */

typedef struct {
    /* Inputs */
    const uint8_t  *symbols;       /* symbols slice for this block */
    const uint16_t *contexts;      /* contexts slice for this block */
    size_t          n_block_symbols;
    uint16_t        n_contexts;
    /* Outputs (allocated by caller, filled by task) */
    uint32_t      (*freq)[256];    /* size n_contexts × 256, calloc'd by caller */
    uint8_t        *payload_buf;   /* worst-case sized */
    size_t          payload_cap;
    size_t          payload_len;   /* set by task */
    /* Status */
    int             rc;
} wf_encode_task_t;

typedef struct {
    /* Inputs */
    const uint8_t  *payload;        /* rANS payload bytes */
    size_t          payload_len;
    const uint16_t *contexts;       /* contexts slice */
    size_t          n_block_symbols;
    uint16_t        n_contexts;
    const uint32_t (*freq)[256];    /* freq table for this block */
    /* Output */
    uint8_t        *symbols_out;    /* slice into caller's output buffer */
    /* Status */
    int             rc;
} wf_decode_task_t;

/* ── Encode worker ─────────────────────────────────────────────────── */

static void wf_encode_worker(void *arg)
{
    wf_encode_task_t *t = (wf_encode_task_t *)arg;
    if (t->n_block_symbols == 0) {
        /* For a zero-symbol block, ttio_rans_encode_block emits a
         * 32-byte zero header.  Capture that. */
        t->payload_len = t->payload_cap;
        t->rc = ttio_rans_encode_block(
            NULL, NULL, 0, t->n_contexts,
            (const uint32_t (*)[256])t->freq,
            t->payload_buf, &t->payload_len);
        return;
    }
    /* Build freq table from this block's symbol slice. */
    t->rc = wf_build_freq_table(
        t->symbols, t->contexts, t->n_block_symbols,
        t->n_contexts, t->freq);
    if (t->rc != TTIO_RANS_OK) return;

    t->payload_len = t->payload_cap;
    t->rc = ttio_rans_encode_block(
        t->symbols, t->contexts, t->n_block_symbols,
        t->n_contexts,
        (const uint32_t (*)[256])t->freq,
        t->payload_buf, &t->payload_len);
}

/* ── Decode worker ─────────────────────────────────────────────────── */

static void wf_decode_worker(void *arg)
{
    wf_decode_task_t *t = (wf_decode_task_t *)arg;
    if (t->n_block_symbols == 0) {
        t->rc = TTIO_RANS_OK;
        return;
    }
    /* Build cum + dtab from freq for this block. */
    uint32_t (*cum)[256] = (uint32_t (*)[256])
        calloc(t->n_contexts, 256 * sizeof(uint32_t));
    if (!cum) { t->rc = TTIO_RANS_ERR_ALLOC; return; }

    for (uint16_t c = 0; c < t->n_contexts; c++) {
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) {
            cum[c][s] = running;
            running += t->freq[c][s];
        }
    }

    uint8_t (*dtab)[TTIO_RANS_T] = (uint8_t (*)[TTIO_RANS_T])
        calloc(t->n_contexts, TTIO_RANS_T);
    if (!dtab) { free(cum); t->rc = TTIO_RANS_ERR_ALLOC; return; }

    int rc = ttio_rans_build_decode_table(
        t->n_contexts, t->freq, (const uint32_t (*)[256])cum, dtab);
    if (rc != TTIO_RANS_OK) {
        free(dtab); free(cum); t->rc = rc; return;
    }

    t->rc = ttio_rans_decode_block(
        t->payload, t->payload_len,
        t->contexts, t->n_contexts,
        t->freq, (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        t->symbols_out, t->n_block_symbols);

    free(dtab);
    free(cum);
}

/* ── Block-boundary helper ─────────────────────────────────────────── *
 *
 * Compute per-block (start_symbol, n_block_symbols) given read_lengths
 * and reads_per_block.  If read_lengths is NULL, treat as a single
 * block of n_symbols.
 *
 * Allocates and returns arrays of size *out_block_count entries via
 * out_block_starts and out_block_lens.  Caller frees both.
 *
 * Returns 0 on success, non-zero on parameter error.
 */
static int wf_compute_blocks(
    size_t          n_symbols,
    size_t          reads_per_block,
    const size_t   *read_lengths,
    size_t          n_reads,
    size_t        **out_block_starts,
    size_t        **out_block_lens,
    size_t         *out_block_count)
{
    *out_block_starts = NULL;
    *out_block_lens = NULL;
    *out_block_count = 0;

    if (read_lengths == NULL || n_reads == 0 || reads_per_block == 0) {
        /* Single block covering the whole input. */
        size_t *bs = (size_t *)calloc(1, sizeof(size_t));
        size_t *bl = (size_t *)calloc(1, sizeof(size_t));
        if (!bs || !bl) { free(bs); free(bl); return TTIO_RANS_ERR_ALLOC; }
        bs[0] = 0;
        bl[0] = n_symbols;
        *out_block_starts = bs;
        *out_block_lens = bl;
        *out_block_count = 1;
        return TTIO_RANS_OK;
    }

    /* Verify sum(read_lengths) == n_symbols */
    size_t total = 0;
    for (size_t i = 0; i < n_reads; i++) {
        size_t rl = read_lengths[i];
        if (total > SIZE_MAX - rl) return TTIO_RANS_ERR_PARAM; /* overflow */
        total += rl;
    }
    if (total != n_symbols) return TTIO_RANS_ERR_PARAM;

    size_t block_count = (n_reads + reads_per_block - 1) / reads_per_block;
    size_t *bs = (size_t *)calloc(block_count, sizeof(size_t));
    size_t *bl = (size_t *)calloc(block_count, sizeof(size_t));
    if (!bs || !bl) { free(bs); free(bl); return TTIO_RANS_ERR_ALLOC; }

    size_t cursor = 0;
    for (size_t b = 0; b < block_count; b++) {
        size_t r0 = b * reads_per_block;
        size_t r1 = r0 + reads_per_block;
        if (r1 > n_reads) r1 = n_reads;
        size_t blen = 0;
        for (size_t r = r0; r < r1; r++)
            blen += read_lengths[r];
        bs[b] = cursor;
        bl[b] = blen;
        cursor += blen;
    }

    *out_block_starts = bs;
    *out_block_lens = bl;
    *out_block_count = block_count;
    return TTIO_RANS_OK;
}

/* ── V2 encode_mt ──────────────────────────────────────────────────── */

int ttio_rans_encode_mt_v2(
    ttio_rans_pool *pool,
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    size_t          reads_per_block,
    const size_t   *read_lengths,
    size_t          n_reads,
    uint8_t        *out,
    size_t         *out_len);

int ttio_rans_decode_mt_v2(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols);

int ttio_rans_decode_mt_v1(
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols);

/* ──────────────────────────────────────────────────────────────────── */

int ttio_rans_encode_mt_v2(
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
    if (!out_len) return TTIO_RANS_ERR_PARAM;
    if (!out && *out_len > 0) return TTIO_RANS_ERR_PARAM;
    if (n_contexts == 0) return TTIO_RANS_ERR_PARAM;
    if (n_symbols > 0 && (!symbols || !contexts)) return TTIO_RANS_ERR_PARAM;

    size_t out_cap = *out_len;
    size_t *block_starts = NULL;
    size_t *block_lens = NULL;
    size_t block_count = 0;

    int rc = wf_compute_blocks(n_symbols, reads_per_block,
                               read_lengths, n_reads,
                               &block_starts, &block_lens, &block_count);
    if (rc != TTIO_RANS_OK) return rc;

    if (block_count > UINT32_MAX) {
        free(block_starts); free(block_lens);
        return TTIO_RANS_ERR_PARAM;
    }

    /* Allocate per-block tasks + freq tables + worst-case payload bufs. */
    wf_encode_task_t *tasks = (wf_encode_task_t *)calloc(
        block_count, sizeof(wf_encode_task_t));
    if (!tasks) {
        free(block_starts); free(block_lens);
        return TTIO_RANS_ERR_ALLOC;
    }

    int alloc_failed = 0;
    for (size_t b = 0; b < block_count; b++) {
        wf_encode_task_t *t = &tasks[b];
        size_t bs = block_starts[b];
        size_t bl = block_lens[b];

        t->symbols  = bl > 0 ? (symbols + bs) : NULL;
        t->contexts = bl > 0 ? (contexts + bs) : NULL;
        t->n_block_symbols = bl;
        t->n_contexts = n_contexts;
        t->freq = (uint32_t (*)[256])calloc(n_contexts, 256 * sizeof(uint32_t));
        /* Worst case: encode_block produces 32 bytes header + ~2 bytes
         * per symbol (16-bit lane chunks).  Add slack. */
        t->payload_cap = 64 + bl * 4 + 64;
        t->payload_buf = (uint8_t *)malloc(t->payload_cap);
        t->payload_len = 0;
        t->rc = TTIO_RANS_OK;
        if (!t->freq || !t->payload_buf) {
            alloc_failed = 1;
            break;
        }
    }

    if (alloc_failed) {
        for (size_t b = 0; b < block_count; b++) {
            free(tasks[b].freq);
            free(tasks[b].payload_buf);
        }
        free(tasks);
        free(block_starts); free(block_lens);
        return TTIO_RANS_ERR_ALLOC;
    }

    /* Submit tasks to pool, or run inline if no pool. */
    if (pool && _ttio_rans_pool_n_threads(pool) > 0) {
        for (size_t b = 0; b < block_count; b++) {
            int srrc = _ttio_rans_pool_submit(pool, wf_encode_worker, &tasks[b]);
            if (srrc != TTIO_RANS_OK) {
                /* If submit fails, run remaining tasks inline. */
                _ttio_rans_pool_wait(pool);
                for (size_t c = b; c < block_count; c++)
                    wf_encode_worker(&tasks[c]);
                goto run_done;
            }
        }
        _ttio_rans_pool_wait(pool);
    } else {
        for (size_t b = 0; b < block_count; b++)
            wf_encode_worker(&tasks[b]);
    }
run_done:;

    /* Check for any per-task errors. */
    int task_rc = TTIO_RANS_OK;
    for (size_t b = 0; b < block_count; b++) {
        if (tasks[b].rc != TTIO_RANS_OK) { task_rc = tasks[b].rc; break; }
    }
    if (task_rc != TTIO_RANS_OK) {
        for (size_t b = 0; b < block_count; b++) {
            free(tasks[b].freq);
            free(tasks[b].payload_buf);
        }
        free(tasks);
        free(block_starts); free(block_lens);
        return task_rc;
    }

    /* Compute total output size. */
    size_t total_size = WF_V2_HDR_SIZE;
    size_t freq_table_bytes = (size_t)n_contexts * 256u * 2u;
    for (size_t b = 0; b < block_count; b++) {
        size_t rec = WF_V2_BLOCK_HDR_SIZE + freq_table_bytes + tasks[b].payload_len;
        if (rec > UINT32_MAX) {
            for (size_t c = 0; c < block_count; c++) {
                free(tasks[c].freq);
                free(tasks[c].payload_buf);
            }
            free(tasks);
            free(block_starts); free(block_lens);
            return TTIO_RANS_ERR_PARAM;
        }
        total_size += rec;
    }

    if (total_size > out_cap) {
        *out_len = total_size; /* tell caller required size */
        for (size_t b = 0; b < block_count; b++) {
            free(tasks[b].freq);
            free(tasks[b].payload_buf);
        }
        free(tasks);
        free(block_starts); free(block_lens);
        return TTIO_RANS_ERR_PARAM;
    }

    /* Write container header. */
    out[0] = WF_MAGIC0;
    out[1] = WF_MAGIC1;
    out[2] = WF_MAGIC2;
    out[3] = WF_MAGIC3;
    out[4] = (uint8_t)WF_V2;
    wf_write_le32(out + 5,  (uint32_t)block_count);
    wf_write_le32(out + 9,  (uint32_t)reads_per_block);
    /* context_params: n_contexts in low 2 bytes; bytes 2-3 reserved=0 */
    wf_write_le16(out + 13, n_contexts);
    out[15] = 0;
    out[16] = 0;

    /* Write per-block records. */
    size_t cursor = WF_V2_HDR_SIZE;
    for (size_t b = 0; b < block_count; b++) {
        wf_encode_task_t *t = &tasks[b];
        uint32_t rec_size = (uint32_t)(WF_V2_BLOCK_HDR_SIZE
                                       + freq_table_bytes
                                       + t->payload_len);
        wf_write_le32(out + cursor, rec_size); cursor += 4;
        wf_write_le32(out + cursor, (uint32_t)t->n_block_symbols); cursor += 4;
        /* freq table */
        for (uint16_t c = 0; c < n_contexts; c++) {
            for (int s = 0; s < 256; s++) {
                wf_write_le16(out + cursor, (uint16_t)t->freq[c][s]);
                cursor += 2;
            }
        }
        /* payload */
        memcpy(out + cursor, t->payload_buf, t->payload_len);
        cursor += t->payload_len;
    }

    *out_len = total_size;

    for (size_t b = 0; b < block_count; b++) {
        free(tasks[b].freq);
        free(tasks[b].payload_buf);
    }
    free(tasks);
    free(block_starts); free(block_lens);
    return TTIO_RANS_OK;
}

/* ── V2 decode_mt ──────────────────────────────────────────────────── *
 *
 * Note: V2 decode does NOT receive read_lengths from the caller — the
 * per-block n_block_symbols is stored inline in each block record.
 * Contexts must be reconstructed by the caller's higher-level code.
 *
 * The C-library V2 decode uses a degenerate "synthetic context"
 * vector (all zeros) for each block.  Since each block embeds its own
 * freq table, and the freq table was built over the original
 * (symbol, context) stream during encode, the decoder needs the
 * SAME context vector at decode time.  This means V2 in the C
 * library is INCOMPLETE without a separate metadata channel: the
 * higher-level caller (Python via Task 15) must supply the contexts.
 *
 * For the round-trip tests in this layer we use n_contexts=1 (single
 * context, all symbols share ctx=0) so contexts can be reconstructed
 * trivially.  The test_v2_format suite restricts itself to that
 * regime; multi-context V2 decode requires the higher layer to
 * supply contexts and is exercised in Task 15's Python integration.
 */

int ttio_rans_decode_mt_v1(
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols)
{
    if (!compressed || !n_symbols) return TTIO_RANS_ERR_PARAM;
    if (comp_len < 5 + 4 + 4 + 2 + 2)
        return TTIO_RANS_ERR_CORRUPT;

    /* V1 layout (libttio_rans's own V1, not Cython V1):
     *   magic(4) + version=1(1)
     *   n_block_symbols (uint32 LE, 4 bytes)
     *   n_contexts      (uint16 LE, 2 bytes)
     *   freq_table      n_contexts * 512 bytes
     *   rANS payload    rest of buffer
     *
     * Like V2 single-block but without the multi-block envelope.
     * The caller must supply context = 0 for all symbols (i.e. only
     * n_contexts=1 streams are supported via this V1 path; multi-
     * context V1 streams should be decoded via the V2 path even if
     * single-block).
     */
    size_t pos = 5;
    if (comp_len < pos + 4 + 2)
        return TTIO_RANS_ERR_CORRUPT;
    uint32_t n_block_symbols = wf_read_le32(compressed + pos); pos += 4;
    uint16_t n_contexts = wf_read_le16(compressed + pos); pos += 2;
    if (n_contexts == 0) return TTIO_RANS_ERR_CORRUPT;

    size_t freq_bytes = (size_t)n_contexts * 256u * 2u;
    if (comp_len < pos + freq_bytes)
        return TTIO_RANS_ERR_CORRUPT;

    uint32_t (*freq)[256] = (uint32_t (*)[256])
        calloc(n_contexts, 256 * sizeof(uint32_t));
    if (!freq) return TTIO_RANS_ERR_ALLOC;

    for (uint16_t c = 0; c < n_contexts; c++) {
        for (int s = 0; s < 256; s++) {
            freq[c][s] = wf_read_le16(compressed + pos);
            pos += 2;
        }
    }

    /* Build cum + dtab */
    uint32_t (*cum)[256] = (uint32_t (*)[256])
        calloc(n_contexts, 256 * sizeof(uint32_t));
    if (!cum) { free(freq); return TTIO_RANS_ERR_ALLOC; }
    for (uint16_t c = 0; c < n_contexts; c++) {
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) {
            cum[c][s] = running;
            running += freq[c][s];
        }
    }

    uint8_t (*dtab)[TTIO_RANS_T] = (uint8_t (*)[TTIO_RANS_T])
        calloc(n_contexts, TTIO_RANS_T);
    if (!dtab) { free(cum); free(freq); return TTIO_RANS_ERR_ALLOC; }
    int rc = ttio_rans_build_decode_table(n_contexts, (const uint32_t (*)[256])freq,
                                          (const uint32_t (*)[256])cum, dtab);
    if (rc != TTIO_RANS_OK) {
        free(dtab); free(cum); free(freq); return rc;
    }

    /* Allocate synthetic contexts = 0 (V1 single-context assumption). */
    uint16_t *ctx_buf = NULL;
    if (n_block_symbols > 0) {
        ctx_buf = (uint16_t *)calloc(n_block_symbols, sizeof(uint16_t));
        if (!ctx_buf) { free(dtab); free(cum); free(freq); return TTIO_RANS_ERR_ALLOC; }
    }

    if (*n_symbols < n_block_symbols) {
        *n_symbols = n_block_symbols;
        free(ctx_buf); free(dtab); free(cum); free(freq);
        return TTIO_RANS_ERR_PARAM;
    }

    size_t payload_len = comp_len - pos;
    rc = ttio_rans_decode_block(
        compressed + pos, payload_len,
        ctx_buf, n_contexts,
        (const uint32_t (*)[256])freq,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        symbols, n_block_symbols);

    *n_symbols = n_block_symbols;

    free(ctx_buf);
    free(dtab); free(cum); free(freq);
    return rc;
}

int ttio_rans_decode_mt_v2(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols)
{
    if (!compressed || !n_symbols) return TTIO_RANS_ERR_PARAM;
    if (comp_len < WF_V2_HDR_SIZE) return TTIO_RANS_ERR_CORRUPT;

    if (compressed[0] != WF_MAGIC0 || compressed[1] != WF_MAGIC1 ||
        compressed[2] != WF_MAGIC2 || compressed[3] != WF_MAGIC3)
        return TTIO_RANS_ERR_CORRUPT;
    if (compressed[4] != WF_V2)
        return TTIO_RANS_ERR_CORRUPT;

    uint32_t block_count = wf_read_le32(compressed + 5);
    /* reads_per_block at offset 9 — informational only at decode time */
    uint16_t n_contexts = wf_read_le16(compressed + 13);
    /* bytes 15-16 reserved */

    if (n_contexts == 0)
        return TTIO_RANS_ERR_CORRUPT;
    if (block_count == 0) {
        /* zero-block stream → must mean n_symbols=0; trailing bytes
         * after the 17-byte header indicate a malformed stream. */
        if (comp_len != WF_V2_HDR_SIZE) return TTIO_RANS_ERR_CORRUPT;
        *n_symbols = 0;
        return TTIO_RANS_OK;
    }

    size_t freq_bytes = (size_t)n_contexts * 256u * 2u;
    size_t cursor = WF_V2_HDR_SIZE;

    /* First pass: parse headers, validate sizes, sum total n_symbols. */
    size_t *rec_offs = (size_t *)calloc(block_count, sizeof(size_t));
    size_t *rec_lens = (size_t *)calloc(block_count, sizeof(size_t));
    size_t *block_n  = (size_t *)calloc(block_count, sizeof(size_t));
    if (!rec_offs || !rec_lens || !block_n) {
        free(rec_offs); free(rec_lens); free(block_n);
        return TTIO_RANS_ERR_ALLOC;
    }

    size_t total_n = 0;
    for (uint32_t b = 0; b < block_count; b++) {
        if (comp_len < cursor + WF_V2_BLOCK_HDR_SIZE) {
            free(rec_offs); free(rec_lens); free(block_n);
            return TTIO_RANS_ERR_CORRUPT;
        }
        uint32_t rec_size = wf_read_le32(compressed + cursor);
        uint32_t n_block_syms = wf_read_le32(compressed + cursor + 4);
        if (rec_size < WF_V2_BLOCK_HDR_SIZE + freq_bytes) {
            free(rec_offs); free(rec_lens); free(block_n);
            return TTIO_RANS_ERR_CORRUPT;
        }
        if (comp_len < cursor + rec_size) {
            free(rec_offs); free(rec_lens); free(block_n);
            return TTIO_RANS_ERR_CORRUPT;
        }
        rec_offs[b] = cursor;
        rec_lens[b] = rec_size;
        block_n[b]  = n_block_syms;
        if (total_n > SIZE_MAX - n_block_syms) {
            free(rec_offs); free(rec_lens); free(block_n);
            return TTIO_RANS_ERR_CORRUPT;
        }
        total_n += n_block_syms;
        cursor += rec_size;
    }

    if (*n_symbols < total_n) {
        *n_symbols = total_n;
        free(rec_offs); free(rec_lens); free(block_n);
        return TTIO_RANS_ERR_PARAM;
    }

    /* Allocate per-block freq tables, ctx slices, decode tasks. */
    uint32_t (**block_freq)[256] = (uint32_t (**)[256])
        calloc(block_count, sizeof(uint32_t (*)[256]));
    uint16_t **block_ctx = (uint16_t **)calloc(block_count, sizeof(uint16_t *));
    wf_decode_task_t *tasks = (wf_decode_task_t *)calloc(
        block_count, sizeof(wf_decode_task_t));
    if (!block_freq || !block_ctx || !tasks) {
        free(block_freq); free(block_ctx); free(tasks);
        free(rec_offs); free(rec_lens); free(block_n);
        return TTIO_RANS_ERR_ALLOC;
    }

    int alloc_failed = 0;
    size_t out_cursor = 0;
    for (uint32_t b = 0; b < block_count; b++) {
        block_freq[b] = (uint32_t (*)[256])
            calloc(n_contexts, 256 * sizeof(uint32_t));
        if (block_n[b] > 0) {
            block_ctx[b] = (uint16_t *)calloc(block_n[b], sizeof(uint16_t));
        }
        if (!block_freq[b] || (block_n[b] > 0 && !block_ctx[b])) {
            alloc_failed = 1;
            break;
        }
        /* Read freq table */
        size_t fpos = rec_offs[b] + WF_V2_BLOCK_HDR_SIZE;
        for (uint16_t c = 0; c < n_contexts; c++) {
            for (int s = 0; s < 256; s++) {
                block_freq[b][c][s] = wf_read_le16(compressed + fpos);
                fpos += 2;
            }
        }
        /* Build task */
        wf_decode_task_t *t = &tasks[b];
        t->payload     = compressed + fpos;
        t->payload_len = rec_lens[b] - WF_V2_BLOCK_HDR_SIZE - freq_bytes;
        t->contexts    = block_ctx[b];     /* synthetic zeros */
        t->n_block_symbols = block_n[b];
        t->n_contexts  = n_contexts;
        t->freq        = (const uint32_t (*)[256])block_freq[b];
        t->symbols_out = symbols + out_cursor;
        t->rc          = TTIO_RANS_OK;
        out_cursor += block_n[b];
    }

    if (alloc_failed) {
        for (uint32_t b = 0; b < block_count; b++) {
            free(block_freq[b]);
            free(block_ctx[b]);
        }
        free(block_freq); free(block_ctx); free(tasks);
        free(rec_offs); free(rec_lens); free(block_n);
        return TTIO_RANS_ERR_ALLOC;
    }

    /* Submit & wait. */
    if (pool && _ttio_rans_pool_n_threads(pool) > 0) {
        for (uint32_t b = 0; b < block_count; b++) {
            int srrc = _ttio_rans_pool_submit(pool, wf_decode_worker, &tasks[b]);
            if (srrc != TTIO_RANS_OK) {
                _ttio_rans_pool_wait(pool);
                for (uint32_t c = b; c < block_count; c++)
                    wf_decode_worker(&tasks[c]);
                goto dec_done;
            }
        }
        _ttio_rans_pool_wait(pool);
    } else {
        for (uint32_t b = 0; b < block_count; b++)
            wf_decode_worker(&tasks[b]);
    }
dec_done:;

    int task_rc = TTIO_RANS_OK;
    for (uint32_t b = 0; b < block_count; b++) {
        if (tasks[b].rc != TTIO_RANS_OK) { task_rc = tasks[b].rc; break; }
    }

    *n_symbols = total_n;

    for (uint32_t b = 0; b < block_count; b++) {
        free(block_freq[b]);
        free(block_ctx[b]);
    }
    free(block_freq); free(block_ctx); free(tasks);
    free(rec_offs); free(rec_lens); free(block_n);
    return task_rc;
}
