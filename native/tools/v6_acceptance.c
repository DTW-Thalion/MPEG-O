/* native/tools/v6_acceptance.c
 *
 * End-to-end acceptance for the V6 engine: encodes a corpus through
 * ttio_m94z_qual_encode exactly as a writer does, block by block, and
 * reports a checksum of every byte produced plus the wall clock.
 *
 * Run it twice, once with TTIO_GPU=off and once with TTIO_GPU=force.
 * The checksums must match: the two engines are required to produce
 * identical streams, and a block that spills mid-run must not be
 * detectable in the output. The times are what the engine is worth on
 * that machine.
 *
 *   v6_acceptance qual.bin lens.bin [threads]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

#include "../include/ttio_rans.h"
#include "../src/m94z_v6.h"
#include "../src/ttio_engine.h"

#define BLOCK_BYTES (64u * 1024u * 1024u)

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
        fprintf(stderr, "usage: %s qual.bin lens.bin [threads]\n", argv[0]);
        return 2;
    }
    int threads = argc > 3 ? atoi(argv[3]) : 16;
    /* The umbrella takes its thread count from the autotune knob, so
     * setting it here is what makes the argument mean anything. */
    ttio_m94z_set_autotune_threads(threads);

    size_t    qn, ln;
    uint8_t  *qual = load(argv[1], &qn);
    uint32_t *lens = load(argv[2], &ln);
    size_t    n_reads = ln / sizeof(uint32_t);

    size_t   cap = BLOCK_BYTES + (4u << 20);
    uint8_t *out = malloc(cap);
    uint8_t *flags = calloc(n_reads ? n_reads : 1, 1);
    if (!out || !flags) { fprintf(stderr, "oom\n"); return 1; }

    printf("engine: %s\n", ttio_engine_active_name());
    printf("gpu available: %d\n", ttio_engine_gpu_available());

    uint64_t h = 1469598103934665603ull;
    uint64_t total_out = 0;
    size_t   blocks = 0, r = 0, off = 0;
    double   t0 = now_s();

    while (r < n_reads) {
        size_t first = r, acc = 0;
        while (r < n_reads && acc + lens[r] <= BLOCK_BYTES) {
            acc += lens[r];
            r++;
        }
        if (acc == 0) { acc = lens[r]; r++; }

        size_t l = cap;
        int rc = ttio_m94z_qual_encode(qual + off, acc, lens + first,
                                       r - first, flags + first, NULL,
                                       TTIO_M94Z_HINT_V6, 0, out, &l);
        if (rc != 0) {
            fprintf(stderr, "block %zu failed: %d\n", blocks, rc);
            return 1;
        }
        if (out[4] != 6) {
            fprintf(stderr, "block %zu is not a V6 stream\n", blocks);
            return 1;
        }
        h = fnv1a(h, out, l);
        total_out += l;
        off += acc;
        blocks++;
    }

    double secs = now_s() - t0;
    printf("blocks: %zu\n", blocks);
    printf("qualities: %zu\n", qn);
    printf("output bytes: %llu\n", (unsigned long long)total_out);
    printf("checksum: %016llx\n", (unsigned long long)h);
    printf("seconds: %.3f\n", secs);
    printf("encode MB/s: %.1f\n", (double)qn / secs / 1.0e6);

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

    free(qual); free(lens); free(out); free(flags);
    return 0;
}
