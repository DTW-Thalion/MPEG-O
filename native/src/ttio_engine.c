/* native/src/ttio_engine.c
 *
 * Engine registry. See ttio_engine.h for what an engine is and why the
 * two implementations have to agree on bytes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "../include/ttio_rans.h"
#include "ttio_engine.h"

#ifndef TTIO_GPU_VK_SONAME
#ifdef _WIN32
#define TTIO_GPU_VK_SONAME "ttio_gpu_vk.dll"
#else
#define TTIO_GPU_VK_SONAME "libttio_gpu_vk.so"
#endif
#endif

/* The CPU engine has no device to contend for: it is the fallback, so
 * it never refuses a block. Its parallelism is the segment pool, which
 * the job's thread count already governs. */
static int cpu_slots(void) { return 1; }

static int cpu_try_acquire(void) { return 1; }

static void cpu_release(void) { }

static const ttio_engine k_cpu = {
    "cpu",
    cpu_slots,
    cpu_try_acquire,
    cpu_release,
    ttio_v6_encode_job_cpu,
};

const ttio_engine *ttio_engine_cpu(void) { return &k_cpu; }

/* -1 means "not read yet"; the environment is consulted once. */
static int                g_mode = -1;
static const ttio_engine *g_test_gpu;

ttio_gpu_mode ttio_gpu_mode_get(void) {
    if (g_mode < 0) {
        const char *v = getenv("TTIO_GPU");
        g_mode = (v != NULL && strcmp(v, "force") == 0) ? TTIO_GPU_FORCE
                                                        : TTIO_GPU_OFF;
    }
    return (ttio_gpu_mode)g_mode;
}

void ttio_gpu_mode_reset(void) { g_mode = -1; }

void ttio_engine_set_test_gpu(const ttio_engine *e) { g_test_gpu = e; }

typedef const ttio_engine *(*ttio_vk_create_fn)(void);

/* Loaded at most once. A machine that cannot provide an engine gets one
 * line on stderr and the CPU path, which is what it would have used
 * anyway; it is information, not a failure. */
static const ttio_engine *load_gpu_engine(void) {
    ttio_vk_create_fn create = NULL;

#ifdef _WIN32
    HMODULE h = LoadLibraryA(TTIO_GPU_VK_SONAME);
    if (h != NULL)
        create = (ttio_vk_create_fn)(void *)GetProcAddress(
            h, "ttio_vk_engine_create");
#else
    void *h = dlopen(TTIO_GPU_VK_SONAME, RTLD_NOW | RTLD_LOCAL);
    if (h != NULL)
        create = (ttio_vk_create_fn)dlsym(h, "ttio_vk_engine_create");
#endif

    if (create == NULL) {
        fprintf(stderr, "ttio: TTIO_GPU=force but %s could not be loaded; "
                        "encoding on CPU\n", TTIO_GPU_VK_SONAME);
        return NULL;
    }

    const ttio_engine *e = create();
    if (e == NULL)
        fprintf(stderr, "ttio: TTIO_GPU=force but no usable GPU device; "
                        "encoding on CPU\n");
    return e;
}

const ttio_engine *ttio_engine_gpu(void) {
    static const ttio_engine *g_gpu;
    static int                g_tried;

    if (g_test_gpu != NULL) return g_test_gpu;
    if (ttio_gpu_mode_get() != TTIO_GPU_FORCE) return NULL;
    if (!g_tried) {
        g_tried = 1;
        g_gpu = load_gpu_engine();
    }
    return g_gpu;
}

int ttio_engine_gpu_available(void) { return ttio_engine_gpu() != NULL; }

const char *ttio_engine_active_name(void) {
    const ttio_engine *gpu = ttio_engine_gpu();
    return gpu != NULL ? gpu->name : k_cpu.name;
}
