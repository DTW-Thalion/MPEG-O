/* native/tests/test_gpu_engine_probe.c
 *
 * Whether the GPU engine comes up, and that it declines cleanly when it
 * cannot. This has to pass on machines with no Vulkan device at all,
 * because most CI runners are exactly that, so the absence path is a
 * result rather than a skip.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/ttio_rans.h"
#include "../src/ttio_engine.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

int main(void) {
    ttio_engine_set_test_gpu(NULL);

    unsetenv("TTIO_GPU");
    ttio_gpu_mode_reset();
    CHECK(ttio_engine_gpu() == NULL,
          "off means no engine and no attempt to load one");
    CHECK(strcmp(ttio_engine_active_name(), "cpu") == 0,
          "active engine stays cpu when off");

    setenv("TTIO_GPU", "force", 1);
    ttio_gpu_mode_reset();
    const ttio_engine *g = ttio_engine_gpu();

    if (g == NULL) {
        printf("ok   no vulkan device available, engine declined cleanly\n");
    } else {
        CHECK(strncmp(g->name, "vulkan:", 7) == 0,
              "engine names itself vulkan:<device>");
        CHECK(g->slots() >= 1, "engine reports at least one slot");
        CHECK(g->try_acquire() == 1, "first slot is grantable");
        g->release();
        CHECK(g->qual_v6_encode != NULL, "engine exposes an encode entry");
        CHECK(strcmp(ttio_engine_active_name(), g->name) == 0,
              "active name reports the vulkan device");
        printf("#    engine: %s, slots %d\n", g->name, g->slots());
    }

    /* Asking twice must not probe twice or leak a second instance. */
    CHECK(ttio_engine_gpu() == g, "the engine is cached across calls");

    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
