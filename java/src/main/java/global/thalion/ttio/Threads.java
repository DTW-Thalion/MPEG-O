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
    private static int savedV6;

    /** A pool of {@code n} workers ({@code null} executor when n <= 1) that
     *  stands the FQZCOMP auto-tune threads down while it exists. */
    /** How many segments of one M94.Z V6 block to code at once, given
     *  how many blocks the pool keeps in flight: clamp(cores / workers,
     *  2, 8).
     *
     *  <p>Total concurrency wants to sit near the core count, and blocks
     *  are worth more than segments where there is a choice, because the
     *  work that is serial per block only overlaps across blocks.
     *  Segments are for the cores the blocks cannot reach. That is what
     *  the floor of two is for.
     *
     *  <p>Python: {@code ttio._threads.resolve_v6_segment_threads};
     *  Objective-C: {@code +[TTIOThreads resolveV6SegmentThreads:]}. */
    public static int resolveV6SegmentThreads(int poolWorkers) {
        int cores = Runtime.getRuntime().availableProcessors();
        int workers = Math.max(1, poolWorkers);
        int n = cores / workers;
        if (n < 2) n = 2;
        if (n > 8) n = 8;
        return n;
    }

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
                    // Different questions, so not one number: the
                    // auto-tune races three candidates and wants one per
                    // worker, while V6 has no candidates and on that
                    // same 1 would code every block's segments in
                    // sequence.
                    savedV6 = global.thalion.ttio.codecs.FqzcompNx16Z.getV6Threads();
                    global.thalion.ttio.codecs.FqzcompNx16Z.setV6Threads(
                        resolveV6SegmentThreads(n));
                }
            }
        }
        public ExecutorService executor() { return executor; }
        @Override public void close() {
            if (executor == null || closed) { closed = true; return; }
            closed = true;
            executor.shutdown();
            synchronized (Threads.class) {
                if (--depth == 0) {
                    global.thalion.ttio.codecs.FqzcompNx16Z.setAutotuneThreads(savedAutotune);
                    global.thalion.ttio.codecs.FqzcompNx16Z.setV6Threads(savedV6);
                }
            }
        }
    }
}
