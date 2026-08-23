package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class ThreadsTest {

    @Test
    void v6SegmentThreadsClampToTheCoreCount() {
        int cores = Runtime.getRuntime().availableProcessors();
        int one = Threads.resolveV6SegmentThreads(1);
        assertEquals(Math.max(2, cores), one,
                     "one block in flight takes the whole machine");
        assertEquals(2, Threads.resolveV6SegmentThreads(cores * 2),
                     "more blocks than cores still leaves the floor of two");
        assertEquals(one, Threads.resolveV6SegmentThreads(0),
                     "zero blocks is read as one");
        for (int blocks = 1; blocks <= cores; blocks *= 2) {
            assertTrue(Threads.resolveV6SegmentThreads(blocks) * blocks <= cores
                       || Threads.resolveV6SegmentThreads(blocks) == 2,
                       "product stays near the core count at " + blocks);
        }
    }

    /** A writer moves the count as blocks come and go. */
    @Test
    void applyingForBlocksInFlightSetsTheRulesValue() {
        org.junit.jupiter.api.Assumptions.assumeTrue(
            global.thalion.ttio.codecs.TtioRansNative.isAvailable(),
            "libttio_rans_jni not loaded");
        int cores = Runtime.getRuntime().availableProcessors();
        int saved = global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads();
        try {
            Threads.applyV6SegmentThreadsForBlocksInFlight(1);
            assertEquals(Threads.resolveV6SegmentThreads(1),
                         global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads());
            Threads.applyV6SegmentThreadsForBlocksInFlight(cores * 2);
            assertEquals(2, global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads(),
                         "more blocks than cores sets the floor");
        } finally {
            global.thalion.ttio.codecs.FqzcompNx16Z.setV6Threads(saved);
        }
    }

    /* The override reaches outside the clamp on purpose: a sweep has to
     * be able to ask for 1 and for more than 8. Parity with the Python
     * and Objective-C resolvers. */
    @Test
    void v6SegmentThreadsOverrideWinsAndReachesOutsideTheClamp() {
        int cores = Runtime.getRuntime().availableProcessors();
        int rule = Threads.resolveV6SegmentThreads(cores * 2);
        try {
            System.setProperty("ttio.v6.segmentThreads", "5");
            assertEquals(5, Threads.resolveV6SegmentThreads(1));
            assertEquals(5, Threads.resolveV6SegmentThreads(cores * 2),
                         "the override wins whatever the worker count");
            System.setProperty("ttio.v6.segmentThreads", "1");
            assertEquals(1, Threads.resolveV6SegmentThreads(1), "below the floor");
            System.setProperty("ttio.v6.segmentThreads", "16");
            assertEquals(16, Threads.resolveV6SegmentThreads(1), "above the cap");
            for (String bad : new String[] { "junk", "0", "-1", " " }) {
                System.setProperty("ttio.v6.segmentThreads", bad);
                assertEquals(rule, Threads.resolveV6SegmentThreads(cores * 2),
                             "\"" + bad + "\" falls through to the rule");
            }
        } finally {
            System.clearProperty("ttio.v6.segmentThreads");
        }
        assertEquals(rule, Threads.resolveV6SegmentThreads(cores * 2));
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

    /** A thread costs about a gibibyte of the pipeline budget, so the
     *  default import count is capped at what a quarter of memory
     *  affords; a count the caller asked for is not capped. */
    @Test
    void importThreadsCapTheDefaultButNotAnExplicitCount() {
        String savedThreads = System.getProperty("ttio.threads");
        String savedImport = System.getProperty("ttio.import.threads");
        try {
            System.clearProperty("ttio.threads");
            System.clearProperty("ttio.import.threads");
            org.junit.jupiter.api.Assumptions.assumeTrue(
                System.getenv("TTIO_THREADS") == null
                && System.getenv("TTIO_IMPORT_THREADS") == null,
                "thread environment set");
            int plain = Threads.resolve(null);
            int imported = Threads.resolveImportThreads();
            assertTrue(imported >= 1, "never zero");
            assertTrue(imported <= plain, "never above the plain default");

            System.setProperty("ttio.threads", "30");
            assertEquals(30, Threads.resolveImportThreads(),
                         "an explicit count is honoured uncapped");
            System.setProperty("ttio.import.threads", "3");
            assertEquals(3, Threads.resolveImportThreads(),
                         "the import knob wins over the thread knob");
            System.clearProperty("ttio.threads");
            assertEquals(3, Threads.resolveImportThreads(),
                         "and wins over the default");
            System.setProperty("ttio.import.threads", "junk");
            System.setProperty("ttio.threads", "12");
            assertEquals(12, Threads.resolveImportThreads(),
                         "junk falls through to the count asked for");
        } finally {
            if (savedThreads == null) System.clearProperty("ttio.threads");
            else System.setProperty("ttio.threads", savedThreads);
            if (savedImport == null) System.clearProperty("ttio.import.threads");
            else System.setProperty("ttio.import.threads", savedImport);
        }
    }
}
