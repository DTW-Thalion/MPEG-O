/* tools/perf/gpu_spike/v6_ref_dump.c  (throwaway, Phase 2 spike)
 *
 * Dumps a fixture the GPU spike can check itself against: one 64 MiB
 * block's worth of V6 segments, the model parameters, and the bytes the
 * shipped CPU chain coder produces for each segment. The CPU encoder is
 * the authority; the GPU kernel has to reproduce these bytes exactly.
 *
 *   v6_ref_dump qual.bin lens.bin out.v6fx [seg_symbols] [max_chains]
 *
 * Build in WSL against the built library:
 *   gcc -O2 -o v6_ref_dump v6_ref_dump.c -I../../../native/src \
 *       -L../../../native/_build -lttio_rans
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "m94z_v6.h"

#define BLOCK_BYTES (64u * 1024u * 1024u)

static void *load(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    void *p = malloc((size_t)n);
    if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "cannot read %s\n", path);
        exit(1);
    }
    fclose(f);
    *len = (size_t)n;
    return p;
}

static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s qual.bin lens.bin out.v6fx "
                        "[seg_symbols] [max_chains]\n", argv[0]);
        return 2;
    }
    uint32_t seg_symbols = argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 0)
                                    : TTIO_V6_DEFAULT_SEG_SYMBOLS;
    uint32_t max_chains = argc > 5 ? (uint32_t)strtoul(argv[5], NULL, 0)
                                   : 4096u;

    size_t    qn, ln;
    uint8_t  *qual = load(argv[1], &qn);
    uint32_t *lens = load(argv[2], &ln);
    size_t    n_reads_all = ln / sizeof(uint32_t);

    /* One block, the size a real encode uses, read-aligned. */
    size_t blk_reads = 0, blk_qual = 0;
    while (blk_reads < n_reads_all
           && blk_qual + lens[blk_reads] <= BLOCK_BYTES) {
        blk_qual += lens[blk_reads];
        blk_reads++;
    }
    if (blk_reads == 0) { fprintf(stderr, "first read exceeds block\n"); return 1; }

    const ttio_v6_param *pm = &TTIO_V6_DEFAULT;
    ttio_v6_alphabet ab;
    ttio_v6_alphabet_build(qual, blk_qual, pm->seed_total, &ab);

    /* Same greedy rule as the codec: whole reads, close at the first
     * boundary at or after seg_symbols. */
    uint32_t *first = malloc(max_chains * 4), *nread = malloc(max_chains * 4);
    uint32_t *qoff  = malloc(max_chains * 4), *nqual = malloc(max_chains * 4);
    uint32_t *rlen  = malloc(max_chains * 4), *roff  = malloc(max_chains * 4);
    size_t n_ch = 0, r = 0, off = 0;
    while (r < blk_reads && n_ch < max_chains) {
        size_t f0 = r, acc = 0;
        while (r < blk_reads && acc < seg_symbols) { acc += lens[r]; r++; }
        first[n_ch] = (uint32_t)f0;
        nread[n_ch] = (uint32_t)(r - f0);
        qoff[n_ch]  = (uint32_t)off;
        nqual[n_ch] = (uint32_t)acc;
        off += acc;
        n_ch++;
    }

    /* Reference bytes from the shipped coder. */
    size_t   cap = (size_t)seg_symbols * 2 + 65536;
    uint8_t *scratch = malloc(cap);
    uint8_t *refbuf = malloc(off + n_ch * 64 + 65536);
    size_t   ref_used = 0;
    for (size_t c = 0; c < n_ch; c++) {
        size_t l = cap;
        int rc = ttio_v6_chain_encode(pm, &ab, qual + qoff[c],
                                      lens + first[c], nread[c], scratch, &l);
        if (rc != 0) { fprintf(stderr, "chain %zu rc %d\n", c, rc); return 1; }
        roff[c] = (uint32_t)ref_used;
        rlen[c] = (uint32_t)l;
        memcpy(refbuf + ref_used, scratch, l);
        ref_used += l;
    }

    /* Dense indices, so the kernel does no mapping. */
    uint8_t *qidx = malloc(off);
    for (size_t i = 0; i < off; i++) qidx[i] = ab.map[qual[i]];

    FILE *out = fopen(argv[3], "wb");
    if (!out) { fprintf(stderr, "cannot write %s\n", argv[3]); return 1; }
    fwrite("V6FX", 1, 4, out);
    put32(out, (uint32_t)n_ch);
    put32(out, (uint32_t)(pm->qbits + pm->pbits + pm->dbits));
    put32(out, pm->qbits);
    put32(out, pm->qshift);
    put32(out, pm->pbits);
    put32(out, pm->pshift);
    put32(out, pm->dbits);
    put32(out, ab.n);
    put32(out, ab.seed_total);
    put32(out, (uint32_t)off);
    put32(out, (uint32_t)blk_reads);
    put32(out, (uint32_t)ref_used);
    for (unsigned i = 0; i < ab.n; i++) put32(out, ab.seed[i]);
    fwrite(first, 4, n_ch, out);
    fwrite(nread, 4, n_ch, out);
    fwrite(qoff, 4, n_ch, out);
    fwrite(nqual, 4, n_ch, out);
    fwrite(roff, 4, n_ch, out);
    fwrite(rlen, 4, n_ch, out);
    fwrite(lens, 4, blk_reads, out);
    fwrite(qidx, 1, off, out);
    fwrite(refbuf, 1, ref_used, out);
    fclose(out);

    printf("chains %zu, symbols %zu, reads %zu, alphabet %u, "
           "seed_total %u, reference %zu bytes\n",
           n_ch, off, blk_reads, ab.n, ab.seed_total, ref_used);
    return 0;
}
