package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class ThreadsTest {

    @Test
    void resolvePrecedence() {
        System.clearProperty("ttio.threads");
        int cores = Runtime.getRuntime().availableProcessors();
        assertEquals(Math.max(1, cores - 8), Threads.resolveIgnoringEnv(null));
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
