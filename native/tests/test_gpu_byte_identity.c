/* native/tests/test_gpu_byte_identity.c
 *
 * The gate that ships or blocks the GPU engine: for every segment of a
 * fixture block, the bytes the GPU kernel produces must equal the bytes
 * the CPU coder produced, exactly. Spilling a block between engines is
 * only safe because this holds.
 *
 * The fixture carries the CPU reference, so this needs no corpus. On a
 * machine with no Vulkan device the test reports that and passes; the
 * CI job is responsible for making sure a device (a software
 * rasteriser is enough) is actually present, because a gate that
 * silently skips proves nothing.
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

typedef struct {
    uint32_t  n_ch, ctx_bits, qbits, qshift, pbits, pshift, dbits;
    uint32_t  nsym, seed_total, n_sym_total, n_reads, ref_bytes;
    uint32_t *seed, *first, *nread, *qoff, *nqual, *roff, *rlen, *lens;
    uint8_t  *qidx, *ref;
} fixture;

static uint32_t rd32(FILE *f) {
    uint32_t v = 0;
    if (fread(&v, 4, 1, f) != 1) { fprintf(stderr, "short fixture\n"); exit(1); }
    return v;
}

static void *rdn(FILE *f, size_t n) {
    void *p = malloc(n ? n : 1);
    if (p == NULL) { fprintf(stderr, "oom\n"); exit(1); }
    if (n && fread(p, 1, n, f) != n) { fprintf(stderr, "short fixture\n"); exit(1); }
    return p;
}

static int load_fixture(const char *path, fixture *fx) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return 0;
    char magic[4];
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "V6FX", 4) != 0) {
        fclose(f);
        return 0;
    }
    fx->n_ch = rd32(f);
    fx->ctx_bits = rd32(f);
    fx->qbits = rd32(f);
    fx->qshift = rd32(f);
    fx->pbits = rd32(f);
    fx->pshift = rd32(f);
    fx->dbits = rd32(f);
    fx->nsym = rd32(f);
    fx->seed_total = rd32(f);
    fx->n_sym_total = rd32(f);
    fx->n_reads = rd32(f);
    fx->ref_bytes = rd32(f);
    fx->seed = rdn(f, 4u * fx->nsym);
    fx->first = rdn(f, 4u * fx->n_ch);
    fx->nread = rdn(f, 4u * fx->n_ch);
    fx->qoff = rdn(f, 4u * fx->n_ch);
    fx->nqual = rdn(f, 4u * fx->n_ch);
    fx->roff = rdn(f, 4u * fx->n_ch);
    fx->rlen = rdn(f, 4u * fx->n_ch);
    fx->lens = rdn(f, 4u * fx->n_reads);
    fx->qidx = rdn(f, fx->n_sym_total);
    fx->ref = rdn(f, fx->ref_bytes);
    fclose(f);
    return 1;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1]
                                : "native/tests/fixtures/v6_gate_small.v6fx";
    fixture fx;
    if (!load_fixture(path, &fx)) {
        printf("FAIL cannot read fixture %s\n", path);
        return 1;
    }
    printf("#    fixture: %u chains, alphabet %u, ctx bits %u\n",
           fx.n_ch, fx.nsym, fx.ctx_bits);

    ttio_engine_set_test_gpu(NULL);
    setenv("TTIO_GPU", "force", 1);
    ttio_gpu_mode_reset();
    const ttio_engine *g = ttio_engine_gpu();
    if (g == NULL) {
        printf("#    no GPU engine on this machine\n");
        printf("ok   gate not applicable here\n");
        printf("all passed\n");
        return 0;
    }
    printf("#    engine: %s\n", g->name);

    /* Rebuild the job the fixture describes. The alphabet and its seed
     * table come from the fixture so the kernel is checked against the
     * exact model the CPU coder used. */
    ttio_v6_alphabet ab;
    memset(&ab, 0, sizeof ab);
    ab.n = fx.nsym;
    ab.seed_total = fx.seed_total;
    for (uint32_t i = 0; i < fx.nsym; i++) {
        ab.seed[i] = (uint16_t)fx.seed[i];
        ab.inv[i] = (uint8_t)i;      /* qidx is already dense */
        ab.map[i] = (uint8_t)i;
    }

    ttio_v6_param pm;
    pm.qbits = (uint8_t)fx.qbits;
    pm.qshift = (uint8_t)fx.qshift;
    pm.pbits = (uint8_t)fx.pbits;
    pm.pshift = (uint8_t)fx.pshift;
    pm.dbits = (uint8_t)fx.dbits;
    pm.seed_total = (uint16_t)fx.seed_total;

    uint8_t **bufs = malloc(fx.n_ch * sizeof *bufs);
    size_t   *lens = malloc(fx.n_ch * sizeof *lens);
    int      *errs = calloc(fx.n_ch, sizeof *errs);
    for (uint32_t c = 0; c < fx.n_ch; c++) {
        lens[c] = fx.nqual[c] + fx.nqual[c] / 2 + 4096;
        bufs[c] = malloc(lens[c]);
    }

    v6_seg *segs = malloc(fx.n_ch * sizeof *segs);
    for (uint32_t c = 0; c < fx.n_ch; c++) {
        segs[c].first_read = fx.first[c];
        segs[c].n_reads = fx.nread[c];
        segs[c].qual_off = fx.qoff[c];
        segs[c].n_qual = fx.nqual[c];
    }

    ttio_v6_job job;
    memset(&job, 0, sizeof job);
    job.pm = &pm;
    job.ab = &ab;
    job.qual = fx.qidx;
    job.read_lengths = fx.lens;
    job.n_reads = fx.n_reads;
    job.n_qualities = fx.n_sym_total;
    job.threads = 1;
    job.segs = segs;
    job.n_segs = fx.n_ch;
    job.bufs = bufs;
    job.lens = lens;
    job.errs = errs;

    int rc = g->qual_v6_encode(&job);
    CHECK(rc == 0, "gpu encode returned success");

    uint32_t good = 0;
    for (uint32_t c = 0; c < fx.n_ch && rc == 0; c++) {
        if (lens[c] != fx.rlen[c]) {
            printf("FAIL chain %u length %zu, cpu produced %u\n", c, lens[c],
                   fx.rlen[c]);
            failures++;
            break;
        }
        if (memcmp(bufs[c], fx.ref + fx.roff[c], fx.rlen[c]) != 0) {
            printf("FAIL chain %u bytes differ from the cpu coder\n", c);
            failures++;
            break;
        }
        good++;
    }
    CHECK(rc == 0 && good == fx.n_ch,
          "every chain is byte-identical to the cpu coder");
    printf("#    %u of %u chains identical\n", good, fx.n_ch);

    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
