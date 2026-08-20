/* native/src/ttio_engine.c
 *
 * Engine registry. See ttio_engine.h for what an engine is and why the
 * two implementations have to agree on bytes.
 */
#include <stdlib.h>
#include <string.h>

#include "../include/ttio_rans.h"
#include "ttio_engine.h"

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

const ttio_engine *ttio_engine_gpu(void) {
    if (g_test_gpu != NULL) return g_test_gpu;
    if (ttio_gpu_mode_get() != TTIO_GPU_FORCE) return NULL;
    /* The Vulkan backend is loaded here once it exists. Until then
     * asking for it politely gets nothing, which is the same answer a
     * machine without a device gives. */
    return NULL;
}

int ttio_engine_gpu_available(void) { return ttio_engine_gpu() != NULL; }

const char *ttio_engine_active_name(void) {
    const ttio_engine *gpu = ttio_engine_gpu();
    return gpu != NULL ? gpu->name : k_cpu.name;
}
