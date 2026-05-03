/* native/tests/test_fqzcomp_qual_threaded.c
 *
 * Threaded-histogram contract test.
 *
 * The auto-tune (strategy_hint = -1) path runs a histogram pass before
 * picking parameters. With TTIO_FQZCOMP_THREADS > 1 the histogram pass
 * partitions records across worker threads and merges per-thread
 * accumulators back into the same final state. The contract: encoded
 * output bytes are identical between the sequential and threaded
 * modes. This test asserts byte-equality on a deterministic synthetic
 * input under several thread counts.
 *
 * The 4-corpus byte-equality gates
 * (python/tests/integration/test_m94z_v4_byte_exact.py and the Java +
 * ObjC mirrors) are the integration tests; this is the fast unit gate.
 */
#include "fqzcomp_qual.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void build_synth(uint8_t *qual, uint32_t *lens, uint8_t *flags,
                        size_t n_reads, size_t read_len)
{
    uint64_t s = 0xBEEFULL;
    for (size_t i = 0; i < n_reads * read_len; i++) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        qual[i] = (uint8_t)(33u + 20u + (uint32_t)((s >> 32) % 21u));
    }
    for (size_t i = 0; i < n_reads; i++) {
        lens[i] = (uint32_t)read_len;
        /* Mix READ1/READ2 (bit 7 = FQZ_FREAD2 in fqz_qual_stats logic) +
         * mix REVERSE (bit 4) so the per-direction qhist1/qhist2 paths
         * and the dedup window both get exercised. */
        flags[i] = (uint8_t)(((i & 1u) << 7) | (((i >> 1) & 1u) << 4));
    }
}

static int encode_once(const uint8_t *qual, size_t n_qual,
                       const uint32_t *lens, size_t n_reads,
                       const uint8_t *flags,
                       uint8_t *out, size_t *out_len)
{
    return ttio_fqzcomp_qual_compress(qual, n_qual, lens, n_reads, flags,
                                       /*strategy_hint=*/-1, out, out_len);
}

static int run_with_threads(const char *thread_count,
                             const uint8_t *qual, size_t n_qual,
                             const uint32_t *lens, size_t n_reads,
                             const uint8_t *flags,
                             uint8_t *out, size_t *out_len)
{
    if (thread_count) setenv("TTIO_FQZCOMP_THREADS", thread_count, 1);
    else              unsetenv("TTIO_FQZCOMP_THREADS");
    return encode_once(qual, n_qual, lens, n_reads, flags, out, out_len);
}

int main(void)
{
    const size_t n_reads = 50000;   /* enough records to partition */
    const size_t read_len = 100;
    const size_t n_qual = n_reads * read_len;

    uint8_t  *qual  = (uint8_t  *)malloc(n_qual);
    uint32_t *lens  = (uint32_t *)malloc(n_reads * sizeof(uint32_t));
    uint8_t  *flags = (uint8_t  *)malloc(n_reads);
    assert(qual && lens && flags);
    build_synth(qual, lens, flags, n_reads, read_len);

    size_t cap = n_qual + 1024;
    uint8_t *out_seq = (uint8_t *)malloc(cap);
    assert(out_seq);
    size_t len_seq = cap;
    int rc = run_with_threads(NULL, qual, n_qual, lens, n_reads, flags,
                              out_seq, &len_seq);
    if (rc != 0) {
        fprintf(stderr, "FAIL: sequential encode rc=%d\n", rc);
        return 1;
    }

    /* Try a range of thread counts. Each must produce identical bytes
     * to the sequential reference — the threaded histogram is required
     * to be byte-equivalent to the serial walk. */
    const char *counts[] = {"1", "2", "3", "4", "8"};
    for (size_t t = 0; t < sizeof(counts) / sizeof(counts[0]); t++) {
        size_t len_par = cap;
        uint8_t *out_par = (uint8_t *)malloc(cap);
        assert(out_par);
        rc = run_with_threads(counts[t], qual, n_qual, lens, n_reads, flags,
                              out_par, &len_par);
        if (rc != 0) {
            fprintf(stderr, "FAIL: threaded(N=%s) rc=%d\n", counts[t], rc);
            return 2;
        }
        if (len_par != len_seq) {
            fprintf(stderr,
                "FAIL: threaded(N=%s) length differs: par=%zu seq=%zu\n",
                counts[t], len_par, len_seq);
            return 3;
        }
        if (memcmp(out_par, out_seq, len_seq) != 0) {
            size_t k = 0;
            while (k < len_seq && out_par[k] == out_seq[k]) k++;
            fprintf(stderr,
                "FAIL: threaded(N=%s) bytes differ at offset %zu of %zu\n",
                counts[t], k, len_seq);
            return 4;
        }
        printf("OK threaded(N=%s): %zu bytes byte-equal sequential\n",
               counts[t], len_par);
        free(out_par);
    }

    free(qual); free(lens); free(flags); free(out_seq);
    printf("test_fqzcomp_qual_threaded: PASS\n");
    return 0;
}
