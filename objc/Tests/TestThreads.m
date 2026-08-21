/* TTIOThreads knob, the auto-tune stand-down, and V6's own segment
 * thread count.
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

    /* clamp(cores / blocksInFlight, 2, cores). The argument is blocks in
     * flight, not the pool size: a run with fewer blocks than workers
     * never fills the pool, and sizing from the pool left 3 blocks
     * asking for 2 threads each on a 32-thread machine. The product
     * blocks x n stays near the core count at every count. */
    NSUInteger c = (NSUInteger)[[NSProcessInfo processInfo] activeProcessorCount];
    NSUInteger one = [TTIOThreads resolveV6SegmentThreads:1];
    PASS(one == (c < 2 ? 2 : c),
         "v6 segments: one block in flight takes the whole machine (%lu of %lu)",
         (unsigned long)one, (unsigned long)c);
    PASS([TTIOThreads resolveV6SegmentThreads:c * 2] == 2,
         "v6 segments: more blocks than cores still leaves the floor of two");
    PASS([TTIOThreads resolveV6SegmentThreads:0] == one,
         "v6 segments: zero blocks is read as one");
    if (c >= 4) {
        NSUInteger half = [TTIOThreads resolveV6SegmentThreads:2];
        PASS(half * 2 <= c && half * 2 >= c - 2,
             "v6 segments: the product stays near the core count (%lu x 2 vs %lu)",
             (unsigned long)half, (unsigned long)c);
    }

    /* The override exists so the split between blocks and segments can
     * be swept. It sits outside the clamp on purpose: a sweep has to be
     * able to ask for 1 and for more than 8. */
    setenv("TTIO_V6_SEGMENT_THREADS", "5", 1);
    PASS([TTIOThreads resolveV6SegmentThreads:1] == 5
         && [TTIOThreads resolveV6SegmentThreads:c * 2] == 5,
         "v6 segments: TTIO_V6_SEGMENT_THREADS wins whatever the worker count");
    setenv("TTIO_V6_SEGMENT_THREADS", "1", 1);
    PASS([TTIOThreads resolveV6SegmentThreads:1] == 1,
         "v6 segments: the override reaches below the floor");
    setenv("TTIO_V6_SEGMENT_THREADS", "16", 1);
    PASS([TTIOThreads resolveV6SegmentThreads:1] == 16,
         "v6 segments: the override reaches above the cap");
    setenv("TTIO_V6_SEGMENT_THREADS", "junk", 1);
    PASS([TTIOThreads resolveV6SegmentThreads:1] == one,
         "v6 segments: junk falls through to the rule");
    setenv("TTIO_V6_SEGMENT_THREADS", "0", 1);
    PASS([TTIOThreads resolveV6SegmentThreads:1] == one,
         "v6 segments: zero falls through to the rule");
    unsetenv("TTIO_V6_SEGMENT_THREADS");
    PASS([TTIOThreads resolveV6SegmentThreads:1] == one,
         "v6 segments: unset falls through to the rule");

    /* The defect this guards: V6 read the auto-tune knob, a pool set
     * that to 1, and V6 has no candidates to race, so every block coded
     * its segments one after another under every writer. */
    int beforeV6 = ttio_m94z_get_v6_threads();
    TTIOThreadPool *p8 = [TTIOThreadPool poolWithThreads:8];
    int inPool = ttio_m94z_get_v6_threads();
    /* Not an equality against resolveV6SegmentThreads:8 — this runs in
     * a suite where an outer pool may already be open, and like the
     * auto-tune the outermost pool is the one that sets the value. What
     * must hold whoever set it is that V6 is not left coding a block's
     * segments one after another, which is the defect this replaced. */
    PASS(inPool > 1,
         "v6 segments: a pool never leaves V6 coding its segments in sequence");
    PASS(inPool >= 2 && inPool <= (int)c,
         "v6 segments: a pool sets a value inside the clamp (%d of %lu)",
         inPool, (unsigned long)c);
    TTIOThreadPool *pNested = [TTIOThreadPool poolWithThreads:16];
    PASS(ttio_m94z_get_v6_threads() == inPool,
         "v6 segments: a nested pool leaves the outer count alone");
    [pNested close];
    PASS(ttio_m94z_get_v6_threads() == inPool,
         "v6 segments: closing the nested pool restores nothing");
    [p8 close];
    PASS(ttio_m94z_get_v6_threads() == beforeV6,
         "v6 segments: restored when the pool that set them closes");

    /* A writer moves the count as blocks come and go, so the value has
     * to follow what it is given rather than staying where the pool put
     * it. Done after the pool assertions: this mutates the same global
     * they are watching. */
    {
        int savedV6 = ttio_m94z_get_v6_threads();
        [TTIOThreads applyV6SegmentThreadsForBlocksInFlight:1];
        PASS(ttio_m94z_get_v6_threads()
                 == (int)[TTIOThreads resolveV6SegmentThreads:1],
             "v6 segments: applying for 1 block in flight sets the rule's value");
        [TTIOThreads applyV6SegmentThreadsForBlocksInFlight:c * 2];
        PASS(ttio_m94z_get_v6_threads() == 2,
             "v6 segments: applying for more blocks than cores sets the floor");
        ttio_m94z_set_v6_threads(savedV6);
    }
}
