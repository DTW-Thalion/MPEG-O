package global.thalion.ttio;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The one thread knob of the SDK: {@code -Dttio.threads}, then
 *  {@code TTIO_THREADS}; unset or 0 means {@code max(1, cores - 8)}; 1 is
 *  the serial path with no executor. */
public final class Threads {
    private Threads() {}

    public static int resolve(Integer explicit) {
        if (explicit != null && explicit > 0) return explicit;
        String raw = System.getProperty("ttio.threads");
        if (raw == null || raw.isBlank()) raw = System.getenv("TTIO_THREADS");
        return fromRaw(raw);
    }

    /** As {@link #resolve} but ignoring the environment (tests). */
    static int resolveIgnoringEnv(Integer explicit) {
        if (explicit != null && explicit > 0) return explicit;
        return fromRaw(System.getProperty("ttio.threads"));
    }

    private static int fromRaw(String raw) {
        int n = 0;
        if (raw != null && !raw.isBlank()) {
            try { n = Integer.parseInt(raw.trim()); } catch (NumberFormatException e) { return 1; }
        }
        // Two cores held back rather than eight: measured throughput
        // kept climbing to roughly one writer per core, and the wider
        // margin left a quarter of it unused. The floor keeps a
        // two-core machine from resolving to zero.
        if (n <= 0) n = Math.max(1, Runtime.getRuntime().availableProcessors() - 2);
        return n;
    }

    /** The pipeline byte budget: {@code explicit} > 0 wins, else the
     *  {@code TTIO_MEMORY_BUDGET} environment variable (bytes), else
     *  {@code max(1 GiB, min(threads * blockBytes * 16, physical / 2))}:
     *  a block in flight costs about eight blockBytes once codec
     *  workspace counts, the writer takes half the budget, so sixteen
     *  per thread admits about one block per thread. */
    public static long resolveMemoryBudget(Long explicitBytes, int threads, long blockBytes) {
        if (explicitBytes != null && explicitBytes > 0) return explicitBytes;
        String raw = System.getenv("TTIO_MEMORY_BUDGET");
        if (raw != null && !raw.isBlank()) {
            try {
                long v = Long.parseLong(raw.trim());
                if (v > 0) return v;
            } catch (NumberFormatException ignored) { }
        }
        long computed = (long) threads * blockBytes * 16L;
        long ramHalf = physicalMemory() / 2;
        if (ramHalf > 0 && computed > ramHalf) computed = ramHalf;
        return Math.max(computed, 1L << 30);
    }

    private static long physicalMemory() {
        try {
            java.lang.management.OperatingSystemMXBean os =
                java.lang.management.ManagementFactory.getOperatingSystemMXBean();
            if (os instanceof com.sun.management.OperatingSystemMXBean b) {
                return b.getTotalMemorySize();
            }
        } catch (Throwable ignored) { }
        return Runtime.getRuntime().maxMemory() * 4;
    }

    private static int depth;
    private static int savedAutotune;

    /** A pool of {@code n} workers ({@code null} executor when n <= 1) that
     *  stands the FQZCOMP auto-tune threads down while it exists. */
    public static PoolScope pool(int n) { return new PoolScope(n); }

    public static final class PoolScope implements AutoCloseable {
        private final ExecutorService executor;
        private boolean closed;
        PoolScope(int n) {
            if (n <= 1) { executor = null; return; }
            executor = Executors.newFixedThreadPool(n, r -> {
                Thread t = new Thread(r, "ttio-block"); t.setDaemon(true); return t; });
            synchronized (Threads.class) {
                if (depth++ == 0) {
                    savedAutotune = global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads();
                    global.thalion.ttio.codecs.FqzcompNx16Z.setAutotuneThreads(1);
                }
            }
        }
        public ExecutorService executor() { return executor; }
        @Override public void close() {
            if (executor == null || closed) { closed = true; return; }
            closed = true;
            executor.shutdown();
            synchronized (Threads.class) {
                if (--depth == 0) global.thalion.ttio.codecs.FqzcompNx16Z.setAutotuneThreads(savedAutotune);
            }
        }
    }
}
