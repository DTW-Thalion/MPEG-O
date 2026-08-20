/* native/bench/bench_v6_ratio.c
 *
 * V6 parameter sweep against the strategy the umbrella picks today.
 *
 *   bench_v6_ratio qual.bin lens.bin seq.bin [threads]
 *
 * The sample is split into read-aligned blocks of at most 64 MiB, the
 * size a real encode uses, so per-block model memory and the number of
 * segments per block are what production would see. Every block is
 * encoded twice: once through ttio_m94z_qual_encode with hint -1 and
 * the sequences present, which is today's best, and once through
 * ttio_m94z_v6_encode for each point in the sweep. Sizes are summed
 * over blocks and reported as a delta against the baseline.
 *
 * Not a test: it needs the benchmark corpora and takes minutes.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/ttio_rans.h"
#include "../src/m94z_v6.h"

#define BLOCK_BYTES (64u * 1024u * 1024u)

typedef struct {
    size_t first_read, n_reads;
    size_t qual_off, n_qual;
} blk;

/* Parse a comma-separated env override, or the default list. */
static size_t axis(const char *env, const char *dflt, unsigned *out) {
    const char *s = getenv(env);
    if (!s || !*s) s = dflt;
    size_t n = 0;
    while (*s && n < 16) {
        out[n++] = (unsigned)strtoul(s, (char **)&s, 10);
        while (*s == ',' || *s == ' ') s++;
    }
    return n;
}

static void *load(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        exit(1);
    }
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

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s qual.bin lens.bin seq.bin [threads]\n", argv[0]);
        return 2;
    }
    int threads = argc > 4 ? atoi(argv[4]) : 16;

    size_t   qn, ln, sn;
    uint8_t *qual = load(argv[1], &qn);
    uint32_t *lens = load(argv[2], &ln);
    uint8_t  *seq = load(argv[3], &sn);
    size_t    n_reads = ln / sizeof(uint32_t);
    if (sn != qn) {
        fprintf(stderr, "seq and qual differ in length\n");
        return 1;
    }

    /* Read-aligned blocks of at most BLOCK_BYTES. */
    blk   *blocks = malloc((qn / BLOCK_BYTES + 2) * sizeof(*blocks));
    size_t n_blk = 0, r = 0, off = 0;
    while (r < n_reads) {
        size_t first = r, acc = 0;
        while (r < n_reads && acc + lens[r] <= BLOCK_BYTES) {
            acc += lens[r];
            r++;
        }
        if (acc == 0) {          /* a read longer than the block target */
            acc = lens[r];
            r++;
        }
        blocks[n_blk].first_read = first;
        blocks[n_blk].n_reads = r - first;
        blocks[n_blk].qual_off = off;
        blocks[n_blk].n_qual = acc;
        off += acc;
        n_blk++;
    }

    size_t   cap = BLOCK_BYTES + (4u << 20);
    uint8_t *out = malloc(cap);
    uint8_t *flags = calloc(n_reads, 1);

    /* Baseline: what the umbrella picks today, with sequences. */
    uint64_t base_total = 0;
    int      base_ver = 0;
    for (size_t b = 0; b < n_blk; b++) {
        size_t l = cap;
        int rc = ttio_m94z_qual_encode(qual + blocks[b].qual_off,
                                       blocks[b].n_qual,
                                       lens + blocks[b].first_read,
                                       blocks[b].n_reads,
                                       flags + blocks[b].first_read,
                                       seq + blocks[b].qual_off,
                                       -1, 0, out, &l);
        if (rc != 0) {
            fprintf(stderr, "baseline block %zu rc %d\n", b, rc);
            return 1;
        }
        base_total += l;
        if (b == 0) base_ver = out[4];
    }
    /* Reference: V4 alone, no sequences. The gap between this and the
     * baseline is what the sequence field is worth on this corpus, and
     * V6 has no sequence field. */
    uint64_t v4_total = 0;
    for (size_t b = 0; b < n_blk; b++) {
        size_t l = cap;
        int rc = ttio_m94z_qual_encode(qual + blocks[b].qual_off,
                                       blocks[b].n_qual,
                                       lens + blocks[b].first_read,
                                       blocks[b].n_reads,
                                       flags + blocks[b].first_read, NULL,
                                       TTIO_M94Z_HINT_V4_AUTO, 0, out, &l);
        if (rc != 0) {
            fprintf(stderr, "v4 reference block %zu rc %d\n", b, rc);
            return 1;
        }
        v4_total += l;
    }

    printf("# corpus %s: %zu reads, %zu qualities, %zu blocks\n", argv[1],
           n_reads, qn, n_blk);
    printf("# baseline (hint -1, sequences present): version %d, "
           "%llu bytes, %.4f bits/qual\n", base_ver,
           (unsigned long long)base_total, 8.0 * (double)base_total / (double)qn);
    printf("# reference (V4 alone, no sequences): %llu bytes, %.4f "
           "bits/qual, %+.2f%% vs baseline\n",
           (unsigned long long)v4_total, 8.0 * (double)v4_total / (double)qn,
           100.0 * ((double)v4_total - (double)base_total) / (double)base_total);
    printf("qbits,qshift,pbits,pshift,dbits,ctx_bits,seg_symbols,"
           "model_MB_per_seg,seed,bytes,bits_per_qual,delta_pct\n");
    fflush(stdout);

    /* Sweep axes, overridable so a diagnostic pass can pin one axis:
     * V6_QBITS=8,10 V6_PBITS=4 V6_DBITS=0,2 V6_QSHIFTS=2,5
     * V6_PSHIFTS=2,4 V6_SEGS=524288 */
    unsigned qbv[16], pbv[16], dbv[16], qsv[16], psv[16];
    uint32_t sgv[16];
    size_t   qbn, pbn, dbn, qsn, psn, sgn, sdn;
    unsigned sdv[16];
    qbn = axis("V6_QBITS", "8,9,10,11,12", qbv);
    pbn = axis("V6_PBITS", "4,5,6", pbv);
    dbn = axis("V6_DBITS", "0,1,2,3", dbv);
    qsn = axis("V6_QSHIFTS", "5", qsv);
    { unsigned t[16]; sdn = axis("V6_SEEDS", "4096", t);
      for (size_t i = 0; i < sdn; i++) sdv[i] = t[i]; }
    psn = axis("V6_PSHIFTS", "4", psv);
    {
        unsigned tmp[16];
        sgn = axis("V6_SEGS", "32768,65536,131072,262144,524288", tmp);
        for (size_t i = 0; i < sgn; i++) sgv[i] = tmp[i];
    }

    for (size_t qi = 0; qi < qbn; qi++) {
        unsigned qb = qbv[qi];
        for (size_t pi = 0; pi < pbn; pi++) {
            unsigned pb = pbv[pi];
            for (size_t di = 0; di < dbn; di++) {
                unsigned db = dbv[di];
                if (qb + pb + db > TTIO_V6_MAX_CTX_BITS) continue;
                for (size_t qsi = 0; qsi < qsn; qsi++)
                for (size_t psi = 0; psi < psn; psi++)
                for (size_t sdi = 0; sdi < sdn; sdi++)
                for (size_t si = 0; si < sgn; si++) {
                    unsigned seed = sdv[sdi];
                    ttio_v6_param pm;
                    pm.qbits = (uint8_t)qb;
                    pm.qshift = (uint8_t)qsv[qsi];
                    pm.pbits = (uint8_t)pb;
                    pm.pshift = (uint8_t)psv[psi];
                    pm.dbits = (uint8_t)db;
                    pm.seed_total = (uint16_t)seed;

                    uint64_t total = 0;
                    int      bad = 0;
                    for (size_t b = 0; b < n_blk && !bad; b++) {
                        size_t l = cap;
                        int rc = ttio_m94z_v6_encode(
                            qual + blocks[b].qual_off, blocks[b].n_qual,
                            lens + blocks[b].first_read, blocks[b].n_reads,
                            &pm, sgv[si], threads, out, &l);
                        if (rc != 0) {
                            fprintf(stderr, "v6 Q%u P%u D%u S%u block %zu "
                                            "rc %d\n", qb, pb, db, sgv[si],
                                    b, rc);
                            bad = 1;
                            break;
                        }
                        total += l;
                    }
                    if (bad) continue;

                    /* Actual model footprint: the dense alphabet sizes
                     * the per-context table, so it is far below the
                     * 256-symbol worst case. */
                    ttio_v6_alphabet probe;
                    ttio_v6_alphabet_build(qual + blocks[0].qual_off,
                                           blocks[0].n_qual, seed, &probe);
                    double model_mb = (double)((size_t)1 << (qb + pb + db))
                                    * (double)(probe.n + 2) * 4.0 / 1048576.0;
                    printf("%u,%u,%u,%u,%u,%u,%u,%.2f,%u,%llu,%.4f,%+.2f\n",
                           qb, pm.qshift, pb, pm.pshift, db, qb + pb + db,
                           sgv[si], model_mb, seed, (unsigned long long)total,
                           8.0 * (double)total / (double)qn,
                           100.0 * ((double)total - (double)base_total)
                               / (double)base_total);
                    fflush(stdout);
                }
            }
        }
    }

    free(qual); free(lens); free(seq); free(blocks); free(out); free(flags);
    return 0;
}
