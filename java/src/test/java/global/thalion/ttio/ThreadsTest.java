package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class ThreadsTest {

    @Test
    void v6SegmentThreadsClampToTheCoreCount() {
        int cores = Runtime.getRuntime().availableProcessors();
        int one = Threads.resolveV6SegmentThreads(1);
        assertEquals(Math.min(8, Math.max(2, cores)), one,
                     "one worker takes the machine, capped at eight");
        assertEquals(2, Threads.resolveV6SegmentThreads(cores * 2),
                     "more workers than cores still leaves the floor of two");
        assertEquals(one, Threads.resolveV6SegmentThreads(0),
                     "zero workers is read as one");
        int mid = Threads.resolveV6SegmentThreads(4);
        assertTrue(mid >= 2 && mid <= 8, "stays inside the clamp");
    }

    /* Exercises the JNI binding as well as the policy: a pool that
     * cannot call setV6Threads would fail here rather than silently
     * leaving V6 coding every block's segments in sequence, which is
     * the defect this replaced. */
    @Test
    void poolGivesV6ItsOwnSegmentThreads() {
        org.junit.jupiter.api.Assumptions.assumeTrue(
            global.thalion.ttio.codecs.TtioRansNative.isAvailable(),
            "libttio_rans_jni not loaded");
        int before = global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads();
        try (Threads.PoolScope scope = Threads.pool(8)) {
            assertEquals(Threads.resolveV6SegmentThreads(8),
                         global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads(),
                         "a pool sets V6 segment threads from its own size");
            assertTrue(global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads() > 1,
                       "a pool never leaves V6 coding its segments in sequence");
            assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads(),
                         "and the auto-tune still stands down");
        }
        assertEquals(before, global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads(),
                     "restored at close");
    }

    @Test
    void resolvePrecedence() {
        System.clearProperty("ttio.threads");
        int cores = Runtime.getRuntime().availableProcessors();
        assertEquals(Math.max(1, cores - 2), Threads.resolveIgnoringEnv(null));
        System.setProperty("ttio.threads", "6");
        assertEquals(6, Threads.resolve(null));
        assertEquals(2, Threads.resolve(2));
        assertEquals(6, Threads.resolve(0));
        System.setProperty("ttio.threads", "junk");
        assertEquals(1, Threads.resolve(null));
        System.clearProperty("ttio.threads");
    }

    @Test
    void poolScopeStandsDownAutotune() {
        if (!global.thalion.ttio.codecs.TtioRansNative.isAvailable()) return;
        int before = global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads();
        try (Threads.PoolScope s = Threads.pool(1)) {
            assertNull(s.executor());
            assertEquals(before, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
        }
        try (Threads.PoolScope s = Threads.pool(4)) {
            assertNotNull(s.executor());
            assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
            try (Threads.PoolScope inner = Threads.pool(2)) {
                assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
            }
            assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
        }
        assertEquals(before, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
    }
}
