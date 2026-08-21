/* native/tools/v6_acceptance.c
 *
 * End-to-end acceptance for V6: encodes a corpus through
 * ttio_m94z_qual_encode exactly as a writer does, block by block,
 * decodes it back through ttio_m94z_qual_decode exactly as a reader
 * does, and reports a checksum, the wall clock for each direction, and
 * whether the round trip returned the input.
 *
 * Both directions take the same two knobs, because both are parallel
 * the same way: `threads` is segments within one block, `blocks` is how
 * many blocks are in flight at once. Their product is what lands on the
 * machine, so a reader that holds four blocks and gives each one thread
 * is using four cores whatever the thread count says.
 *
 *   v6_acceptance qual.bin lens.bin [threads] [blocks] [encode|both]
 *
 * Default is both. `encode` skips the decode pass, which is the older
 * behaviour and what the encode-only figures were measured with.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

#include "../include/ttio_rans.h"
#include "../src/m94z_v6.h"
#include "../src/ttio_engine.h"

#define BLOCK_BYTES (64u * 1024u * 1024u)

typedef struct {
    size_t first_read, n_reads, qual_off, n_qual;
} blk;

typedef struct {
    const blk       *blocks;
    size_t           n_blk;
    size_t           next;
    const uint8_t   *qual;
    const uint32_t  *lens;
    const uint8_t   *flags;
    uint8_t        **outs;
    size_t          *outl;
    int             *rcs;
    pthread_mutex_t  mu;
} enc_ctx;

static void *enc_worker(void *arg) {
    enc_ctx *c = arg;
    for (;;) {
        size_t b;
        pthread_mutex_lock(&c->mu);
        b = c->next++;
        pthread_mutex_unlock(&c->mu);
        if (b >= c->n_blk) break;
        size_t l = c->outl[b];
        c->rcs[b] = ttio_m94z_qual_encode(
            c->qual + c->blocks[b].qual_off, c->blocks[b].n_qual,
            c->lens + c->blocks[b].first_read, c->blocks[b].n_reads,
            c->flags + c->blocks[b].first_read, NULL,
            TTIO_M94Z_HINT_V6, 0, c->outs[b], &l);
        if (c->rcs[b] == 0) c->outl[b] = l;
    }
    return NULL;
}

/* Decode is the mirror of the encode pass: the same block-at-a-time
 * pool, so the two numbers are comparable. Blocks write into disjoint
 * ranges of one output buffer rather than into per-block buffers, which
 * keeps the extra memory to one copy of the corpus and lets the whole
 * result be compared in one go afterwards. */
typedef struct {
    const blk       *blocks;
    size_t           n_blk;
    size_t           next;
    uint8_t *const  *outs;
    const size_t    *outl;
    uint8_t         *qual_out;
    uint32_t        *lens_out;
    int             *rcs;
    pthread_mutex_t  mu;
} dec_ctx;

static void *dec_worker(void *arg) {
    dec_ctx *c = arg;
    for (;;) {
        size_t b;
        pthread_mutex_lock(&c->mu);
        b = c->next++;
        pthread_mutex_unlock(&c->mu);
        if (b >= c->n_blk) break;
        /* V6 carries its own read-length table and needs no sequences,
         * so decode fills the lengths rather than being told them. */
        c->rcs[b] = ttio_m94z_qual_decode(
            c->outs[b], c->outl[b],
            c->lens_out + c->blocks[b].first_read, c->blocks[b].n_reads,
            NULL, NULL,
            c->qual_out + c->blocks[b].qual_off, c->blocks[b].n_qual);
    }
    return NULL;
}

static void run_pool(void *(*fn)(void *), void *ctx, int workers) {
    pthread_t th[64];
    int       started = 0;
    for (int i = 0; i < workers - 1 && i < 64; i++)
        if (pthread_create(&th[i], NULL, fn, ctx) == 0) started++;
    fn(ctx);
    for (int i = 0; i < started; i++) pthread_join(th[i], NULL);
}

/* clock() means different things on different runtimes and counts CPU
 * rather than elapsed time on some, which is useless for a wall-clock
 * comparison between an engine that spins and one that waits. */
static double now_s(void) {
#ifdef _WIN32
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
#endif
}

static void *load(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    /* long is 32-bit on Windows, so ftell cannot describe a file of
     * 2 GB or more, which these corpora reach. */
#ifdef _WIN32
    _fseeki64(f, 0, SEEK_END);
    long long n = _ftelli64(f);
    _fseeki64(f, 0, SEEK_SET);
#else
    fseeko(f, 0, SEEK_END);
    off_t n = ftello(f);
    fseeko(f, 0, SEEK_SET);
#endif
    if (n < 0) {
        fprintf(stderr, "cannot size %s\n", path);
        exit(1);
    }
    void *p = malloc((size_t)n);
    if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "cannot read %s\n", path);
        exit(1);
    }
    fclose(f);
    *len = (size_t)n;
    return p;
}

/* FNV-1a over every output byte: cheap, and different engines
 * producing different bytes cannot collide by accident here. */
static uint64_t fnv1a(uint64_t h, const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ull;
    }
    return h;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,
                "usage: %s qual.bin lens.bin [threads] [blocks] "
                "[encode|both]\n", argv[0]);
        return 2;
    }
    int do_decode = !(argc > 5 && strcmp(argv[5], "encode") == 0);
    int threads = argc > 3 ? atoi(argv[3]) : 16;
    /* The umbrella takes its thread count from the autotune knob, so
     * setting it here is what makes the argument mean anything. */
    ttio_m94z_set_autotune_threads(threads);
    /* How many blocks the caller keeps outstanding. Matching it to the
     * engine's slot count is what fills the device. */
    int writers = argc > 4 ? atoi(argv[4]) : 1;

    size_t    qn, ln;
    uint8_t  *qual = load(argv[1], &qn);
    uint32_t *lens = load(argv[2], &ln);
    size_t    n_reads = ln / sizeof(uint32_t);

    uint8_t *flags = calloc(n_reads ? n_reads : 1, 1);
    if (!flags) { fprintf(stderr, "oom\n"); return 1; }

    printf("engine: %s\n", ttio_engine_active_name());
    printf("gpu available: %d\n", ttio_engine_gpu_available());

    /* Plan the blocks first, then encode them concurrently: a writer
     * with several blocks outstanding is what lets an engine with more
     * than one slot actually overlap work, and a sequential loop hides
     * that no matter how many slots the engine offers. Output is
     * collected per block and checksummed in order afterwards, so the
     * result does not depend on completion order. */
    size_t max_blocks = qn / BLOCK_BYTES + 2;
    blk   *blocks = malloc(max_blocks * sizeof *blocks);
    size_t n_blk = 0, r = 0, off = 0;
    while (r < n_reads) {
        size_t first = r, acc = 0;
        while (r < n_reads && acc + lens[r] <= BLOCK_BYTES) {
            acc += lens[r];
            r++;
        }
        if (acc == 0) { acc = lens[r]; r++; }
        blocks[n_blk].first_read = first;
        blocks[n_blk].n_reads = r - first;
        blocks[n_blk].qual_off = off;
        blocks[n_blk].n_qual = acc;
        off += acc;
        n_blk++;
    }

    uint8_t **outs = calloc(n_blk, sizeof *outs);
    size_t   *outl = calloc(n_blk, sizeof *outl);
    int      *rcs = calloc(n_blk, sizeof *rcs);
    for (size_t b = 0; b < n_blk; b++) {
        outl[b] = blocks[b].n_qual + blocks[b].n_qual / 2 + (4u << 20);
        outs[b] = malloc(outl[b]);
        if (outs[b] == NULL) { fprintf(stderr, "oom\n"); return 1; }
    }

    enc_ctx ctx;
    ctx.blocks = blocks;
    ctx.n_blk = n_blk;
    ctx.next = 0;
    ctx.qual = qual;
    ctx.lens = lens;
    ctx.flags = flags;
    ctx.outs = outs;
    ctx.outl = outl;
    ctx.rcs = rcs;
    pthread_mutex_init(&ctx.mu, NULL);

    int workers = writers;
    if (workers > (int)n_blk) workers = (int)n_blk;
    if (workers < 1) workers = 1;

    double t0 = now_s();
    run_pool(enc_worker, &ctx, workers);
    double enc_secs = now_s() - t0;

    uint64_t h = 1469598103934665603ull;
    uint64_t total_out = 0;
    for (size_t b = 0; b < n_blk; b++) {
        if (rcs[b] != 0) {
            fprintf(stderr, "block %zu failed: %d\n", b, rcs[b]);
            return 1;
        }
        if (outs[b][4] != 6) {
            fprintf(stderr, "block %zu is not a V6 stream\n", b);
            return 1;
        }
        h = fnv1a(h, outs[b], outl[b]);
        total_out += outl[b];
    }

    printf("blocks: %zu\n", n_blk);
    printf("blocks in flight: %d, engine slots: %d\n", workers,
           ttio_engine_gpu() ? ttio_engine_gpu()->slots() : 0);
    printf("qualities: %zu\n", qn);
    printf("output bytes: %llu\n", (unsigned long long)total_out);
    printf("checksum: %016llx\n", (unsigned long long)h);
    printf("seconds: %.3f\n", enc_secs);
    printf("encode MB/s: %.1f\n", (double)qn / enc_secs / 1.0e6);

    if (do_decode) {
        uint8_t  *dqual = malloc(qn ? qn : 1);
        uint32_t *dlens = malloc(ln ? ln : 1);
        if (dqual == NULL || dlens == NULL) { fprintf(stderr, "oom\n"); return 1; }
        /* Fill with something the corpus is unlikely to be, so a decode
         * that silently writes nothing fails the comparison instead of
         * matching a zeroed buffer. */
        memset(dqual, 0xA5, qn);
        memset(dlens, 0xA5, ln);

        dec_ctx dc;
        dc.blocks = blocks;
        dc.n_blk = n_blk;
        dc.next = 0;
        dc.outs = outs;
        dc.outl = outl;
        dc.qual_out = dqual;
        dc.lens_out = dlens;
        dc.rcs = rcs;
        pthread_mutex_init(&dc.mu, NULL);

        double d0 = now_s();
        run_pool(dec_worker, &dc, workers);
        double dec_secs = now_s() - d0;

        for (size_t b = 0; b < n_blk; b++) {
            if (rcs[b] != 0) {
                fprintf(stderr, "block %zu failed to decode: %d\n", b, rcs[b]);
                return 1;
            }
        }
        if (memcmp(dqual, qual, qn) != 0) {
            size_t i = 0;
            while (i < qn && dqual[i] == qual[i]) i++;
            fprintf(stderr, "round trip differs at quality byte %zu: "
                            "got %u want %u\n", i, dqual[i], qual[i]);
            return 1;
        }
        if (memcmp(dlens, lens, ln) != 0) {
            fprintf(stderr, "round trip lost the read lengths\n");
            return 1;
        }
        printf("decode seconds: %.3f\n", dec_secs);
        printf("decode MB/s: %.1f\n", (double)qn / dec_secs / 1.0e6);
        printf("round trip: identical\n");
        free(dqual);
        free(dlens);
    }

    {
        const ttio_engine *e = ttio_engine_gpu();
        if (e != NULL && e->debug_stat != NULL) {
            printf("upload ms: %.1f\n",
                   e->debug_stat(TTIO_ENGINE_STAT_UPLOAD_US) / 1000.0);
            printf("kernel ms: %.1f\n",
                   e->debug_stat(TTIO_ENGINE_STAT_KERNEL_US) / 1000.0);
            printf("readback ms: %.1f\n",
                   e->debug_stat(TTIO_ENGINE_STAT_READBACK_US) / 1000.0);
            printf("engine calls: %d, succeeded: %d\n",
                   e->debug_stat(TTIO_ENGINE_STAT_CALLS),
                   e->debug_stat(TTIO_ENGINE_STAT_OK));
            printf("engine total ms: %.1f\n",
                   e->debug_stat(TTIO_ENGINE_STAT_TOTAL_US) / 1000.0);
#ifdef _WIN32
            {
                HMODULE h = GetModuleHandleA("libttio_gpu_vk.dll");
                const char *(*lf)(int *) = h
                    ? (const char *(*)(int *))(void *)GetProcAddress(
                          h, "ttio_vk_last_failure")
                    : NULL;
                if (lf != NULL) {
                    int code = 0;
                    const char *why = lf(&code);
                    printf("engine last failure: %s (code %d)\n", why, code);
                }
            }
#endif
        }
    }

    free(qual); free(lens); free(flags);
    return 0;
}
