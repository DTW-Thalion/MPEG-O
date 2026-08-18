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
        if (n <= 0) n = Math.max(1, Runtime.getRuntime().availableProcessors() - 8);
        return n;
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
