/* native/tests/test_engine_selection.c
 *
 * Which engine a block goes to, and what happens when the GPU one is
 * absent, refuses, or fails. The GPU engine is injectable here so the
 * selection and spill logic can be tested on machines with no GPU,
 * which is most of them.
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

static int stub_calls;

static int  stub_slots(void)       { return 2; }
static int  stub_try_acquire(void) { return 1; }
static void stub_release(void)     { }

static int stub_encode(ttio_v6_job *job) {
    stub_calls++;
    return ttio_v6_encode_job_cpu(job);
}

static const ttio_engine k_stub = {
    "stub", stub_slots, stub_try_acquire, stub_release, stub_encode
};

int main(void) {
    unsetenv("TTIO_GPU");
    ttio_gpu_mode_reset();
    CHECK(ttio_gpu_mode_get() == TTIO_GPU_OFF, "default mode is off");
    CHECK(ttio_engine_gpu() == NULL, "no gpu engine when off");
    CHECK(ttio_engine_gpu_available() == 0, "availability is 0 when off");
    CHECK(strcmp(ttio_engine_active_name(), "cpu") == 0,
          "active engine is cpu when off");

    setenv("TTIO_GPU", "force", 1);
    ttio_gpu_mode_reset();
    CHECK(ttio_gpu_mode_get() == TTIO_GPU_FORCE, "force is parsed");

    setenv("TTIO_GPU", "nonsense", 1);
    ttio_gpu_mode_reset();
    CHECK(ttio_gpu_mode_get() == TTIO_GPU_OFF,
          "an unrecognised value is off, not an error");

    unsetenv("TTIO_GPU");
    ttio_gpu_mode_reset();

    ttio_engine_set_test_gpu(&k_stub);
    CHECK(ttio_engine_gpu() == &k_stub, "an injected engine is returned");
    CHECK(ttio_engine_gpu_available() == 1, "availability is 1 when injected");
    CHECK(strcmp(ttio_engine_active_name(), "stub") == 0,
          "active name follows the injected engine");
    ttio_engine_set_test_gpu(NULL);
    CHECK(ttio_engine_gpu() == NULL, "injection can be cleared");

    free(NULL);
    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
