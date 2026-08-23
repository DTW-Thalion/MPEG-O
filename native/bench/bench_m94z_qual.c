/* One M94.Z qualities encode, on its own, over real data.
 *
 * The qualities channel is the largest single cost in a genomic import,
 * and inside a full import it is reached through samtools, the SAM
 * parse and the block writer, none of which a profiler can be pointed
 * past: valgrind cannot launch the samtools subprocess at all. This
 * runs the codec and nothing else, so callgrind and perf have a target.
 *
 * Usage:
 *   bench_m94z_qual <in.fastq> [max_reads] [hint]
 *
 * hint is 7 for V4 with its own preset selection (the default a writer
 * picks) or 8 for V6. Reads the quality lines of a plain FASTQ.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <in.fastq> [max_reads] [hint 7=V4 8=V6]\n",
                argv[0]);
        return 2;
    }
    size_t max_reads = argc > 2 ? strtoull(argv[2], NULL, 10) : 1000000;
    int    hint      = argc > 3 ? atoi(argv[3]) : TTIO_M94Z_HINT_V4_AUTO;

    FILE *f = fopen(argv[1], "r");
    if (!f) { perror("open"); return 2; }

    size_t cap_q = 1u << 20, n_q = 0;
    size_t cap_r = 1u << 16, n_r = 0;
    uint8_t  *qual = malloc(cap_q);
    uint32_t *lens = malloc(cap_r * sizeof(uint32_t));
    char     *line = NULL;
    size_t    line_cap = 0;
    long      which = 0;

    /* FASTQ is four lines a record; the fourth is the qualities. */
    while (n_r < max_reads) {
        ssize_t got = getline(&line, &line_cap, f);
        if (got < 0) break;
        if (got > 0 && line[got - 1] == '\n') got--;
        if ((which & 3) == 3 && got > 0) {
            while (n_q + (size_t)got > cap_q) {
                cap_q *= 2;
                qual = realloc(qual, cap_q);
            }
            if (n_r == cap_r) {
                cap_r *= 2;
                lens = realloc(lens, cap_r * sizeof(uint32_t));
            }
            memcpy(qual + n_q, line, (size_t)got);
            n_q += (size_t)got;
            lens[n_r++] = (uint32_t)got;
        }
        which++;
    }
    free(line);
    fclose(f);

    if (n_r == 0) { fprintf(stderr, "no reads\n"); return 2; }

    size_t   out_cap = n_q + (n_q >> 1) + (1u << 20);
    uint8_t *out = malloc(out_cap);
    size_t   out_len = out_cap;

    double t0 = now_seconds();
    int rc = ttio_m94z_qual_encode(qual, n_q, lens, n_r, NULL, NULL,
                                   hint, 0, out, &out_len);
    double dt = now_seconds() - t0;

    if (rc != 0) { fprintf(stderr, "encode failed rc=%d\n", rc); return 1; }
    printf("[bench] hint %d: %zu reads, %zu quality bytes in %.3f s: "
           "%.1f MB/s, out %zu bytes (%.2f%% of input)\n",
           hint, n_r, n_q, dt, n_q / 1048576.0 / dt, out_len,
           out_len * 100.0 / (double)n_q);
    free(qual); free(lens); free(out);
    return 0;
}
