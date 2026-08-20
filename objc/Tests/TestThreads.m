/* TTIOThreads knob and TTIOThreadPool auto-tune stand-down.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOThreads.h"
#include <stdlib.h>
#include "ttio_rans.h"

void testThreads(void);
void testThreads(void)
{
    unsetenv("TTIO_THREADS");
    NSUInteger cores = (NSUInteger)[[NSProcessInfo processInfo] activeProcessorCount];
    NSUInteger want = cores > 3 ? cores - 2 : 1;
    PASS([TTIOThreads resolve:nil] == want, "threads: default is cores minus 2, at least 1");
    setenv("TTIO_THREADS", "6", 1);
    PASS([TTIOThreads resolve:nil] == 6, "threads: TTIO_THREADS wins over the default");
    PASS([TTIOThreads resolve:@2] == 2, "threads: an explicit value wins");
    PASS([TTIOThreads resolve:@0] == 6, "threads: explicit 0 defers to the environment");
    setenv("TTIO_THREADS", "junk", 1);
    PASS([TTIOThreads resolve:nil] == 1, "threads: junk resolves to 1");
    unsetenv("TTIO_THREADS");

    int before = ttio_m94z_get_autotune_threads();
    TTIOThreadPool *p1 = [TTIOThreadPool poolWithThreads:1];
    PASS(p1.queue == nil && ttio_m94z_get_autotune_threads() == before,
         "threads: a one-thread pool has no queue and leaves the auto-tune alone");
    [p1 close];
    TTIOThreadPool *p4 = [TTIOThreadPool poolWithThreads:4];
    PASS(p4.queue != nil && p4.queue.maxConcurrentOperationCount == 4,
         "threads: a pool has a queue of its size");
    PASS(ttio_m94z_get_autotune_threads() == 1, "threads: the auto-tune stands down while a pool exists");
    TTIOThreadPool *p2 = [TTIOThreadPool poolWithThreads:2];
    PASS(ttio_m94z_get_autotune_threads() == 1, "threads: nested pools keep it down");
    [p2 close];
    PASS(ttio_m94z_get_autotune_threads() == 1, "threads: still down while the outer pool exists");
    [p4 close];
    PASS(ttio_m94z_get_autotune_threads() == before, "threads: restored at close");
}
