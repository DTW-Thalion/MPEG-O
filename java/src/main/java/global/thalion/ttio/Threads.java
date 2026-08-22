package global.thalion.ttio;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The one thread knob of the SDK: {@code -Dttio.threads}, then
 *  {@code TTIO_THREADS}; unset or 0 means {@code max(1, cores - 2)}; 1 is
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

    /** The block size both importers hand
     *  {@link #resolveMemoryBudget}, and so the per-thread cost of the
     *  budget: {@code IMPORT_BLOCK_BYTES * 16}. */
    private static final long IMPORT_BLOCK_BYTES = 64L << 20;

    /** Threads for an import pipeline when the caller names no count.
     *
     *  <p>The pipeline byte budget is {@code threads * blockBytes * 16}
     *  and the batch assembler and the writer take half each, so the
     *  thread knob sets residency as well as concurrency: one thread
     *  costs about a gibibyte of the budget at the 64 MiB block the
     *  importers use. On a 32-thread, 31 GiB box the {@code cores - 2}
     *  default asks for 30 GiB, takes the half-memory clamp instead,
     *  and a short-read FASTQ import settles at about 17.5 GiB
     *  resident.
     *
     *  <p>Short reads are the case that reaches the clamp. A block of
     *  150 bp records holds a million reads where the same block of
     *  HiFi holds a few thousand, so the pipeline runs out of memory
     *  well before it runs out of cores: measured on 27 M Illumina
     *  reads, 4 to 30 threads moved peak residency 9.8 -> 17.5 GiB for
     *  a throughput gain that stops paying in the single digits.
     *
     *  <p>So cap the default at the count a quarter of physical memory
     *  affords. An explicit thread count is honoured as asked;
     *  {@code TTIO_IMPORT_THREADS} (or {@code -Dttio.import.threads})
     *  overrides this rule alone. Python:
     *  {@code ttio._threads.resolve_import_threads}; Objective-C:
     *  {@code +[TTIOThreads resolveImportThreads]}. */
    public static int resolveImportThreads() {
        String raw = System.getProperty("ttio.import.threads");
        if (raw == null || raw.isBlank()) raw = System.getenv("TTIO_IMPORT_THREADS");
        if (raw != null && !raw.isBlank()) {
            try {
                int n = Integer.parseInt(raw.trim());
                if (n > 0) return n;
            } catch (NumberFormatException ignored) { }
        }
        int threads = resolve(null);
        // A count the caller asked for is a count the caller gets.
        String asked = System.getProperty("ttio.threads");
        if (asked == null || asked.isBlank()) asked = System.getenv("TTIO_THREADS");
        if (asked != null && !asked.isBlank()) return threads;
        long phys = physicalMemory();
        if (phys <= 0) return threads;
        long afford = (phys / 4) / (IMPORT_BLOCK_BYTES * 16L);
        if (afford < 1) afford = 1;
        return (int) Math.min((long) threads, afford);
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

    /** Set the V6 segment thread count from the blocks in flight right
     *  now. A writer calls this as it submits, so the count follows the
     *  work rather than the pool's size; {@link PoolScope#close} restores
     *  the previous value. Python:
     *  {@code ttio._threads.apply_v6_segment_threads}; Objective-C:
     *  {@code +[TTIOThreads applyV6SegmentThreadsForBlocksInFlight:]}. */
    public static void applyV6SegmentThreadsForBlocksInFlight(int blocksInFlight) {
        global.thalion.ttio.codecs.FqzcompNx16Z.setV6Threads(
            resolveV6SegmentThreads(blocksInFlight));
    }

    /** How many segments of one M94.Z V6 block to code at once, given
     *  how many blocks are in flight: clamp(cores / blocksInFlight, 2,
     *  cores).
     *
     *  <p>The argument is the blocks actually in flight, not the pool's
     *  size. A run with fewer blocks than workers never fills the pool,
     *  and sizing from the worker count leaves the machine idle in
     *  exactly that case: 3 blocks against 30 workers asked for 2
     *  segment threads each and used 6 cores of 32. Measured on the
     *  Objective-C writer, following the blocks is worth 11.5% there.
     *  The cap is the core count, not 8, for the same reason.
     *
     *  <p>Total concurrency wants to sit near the core count, and blocks
     *  are worth more than segments where there is a choice, because the
     *  work that is serial per block only overlaps across blocks.
     *  Segments are for the cores the blocks cannot reach. That is what
     *  the floor of two is for.
     *
     *  <p>{@code -Dttio.v6.segmentThreads}, then
     *  {@code TTIO_V6_SEGMENT_THREADS}, overrides the rule when it is a
     *  positive integer, so the split between blocks and segments can
     *  be measured rather than argued; see the Objective-C
     *  {@code TtioGenomicWriteBench}. The override reaches outside the
     *  clamp on purpose: a sweep has to be able to ask for 1 and for
     *  more than 8.
     *
     *  <p>Python: {@code ttio._threads.resolve_v6_segment_threads};
     *  Objective-C: {@code +[TTIOThreads resolveV6SegmentThreads:]}. */
    public static int resolveV6SegmentThreads(int blocksInFlight) {
        String raw = System.getProperty("ttio.v6.segmentThreads");
        if (raw == null || raw.isBlank()) raw = System.getenv("TTIO_V6_SEGMENT_THREADS");
        if (raw != null && !raw.isBlank()) {
            try {
                int v = Integer.parseInt(raw.trim());
                if (v > 0) return v;
            } catch (NumberFormatException ignored) {
                // fall through to the rule
            }
        }
        int cores = Runtime.getRuntime().availableProcessors();
        int blocks = Math.max(1, blocksInFlight);
        int n = cores / blocks;
        if (n < 2) n = 2;
        if (n > cores) n = cores;
        return n;
    }

    /** A pool of {@code n} workers ({@code null} executor when n <= 1)
     *  that stands the FQZCOMP auto-tune threads down while it exists. */
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
