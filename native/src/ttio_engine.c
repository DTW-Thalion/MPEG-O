/* native/src/ttio_engine.c
 *
 * Engine registry. See ttio_engine.h for what an engine is and why the
 * two implementations have to agree on bytes.
 */
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

const char *ttio_engine_active_name(void) { return k_cpu.name; }
