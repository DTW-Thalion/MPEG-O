package global.thalion.ttio.browser.diag;

import java.util.List;
import java.util.Locale;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Static registry of external dependency probes plus a small cache.
 *
 * <p>Call {@link #probeAll()} (typically when the Diagnostics dialog opens)
 * to refresh the cached results. {@link #cached()} returns the most recent
 * snapshot without re-probing; {@link #isAvailable(String)} is a convenience
 * for feature gating.
 */
public final class Diagnostics {

    /**
     * Linux/macOS often have {@code python3} but not {@code python}; Windows
     * typically ships {@code python.exe}. We pick a reasonable platform default
     * so the Bruker helper probe doesn't always report NOT_FOUND on Linux.
     */
    private static final String PYTHON_EXEC =
        System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")
            ? "python" : "python3";

    private static final List<BinaryProbe> PROBES = List.of(
        new BinaryProbe("HDF5 (in-process JNI)", () -> {
            int[] v = new int[3];
            hdf.hdf5lib.H5.H5get_libversion(v);
            return v[0] + "." + v[1] + "." + v[2];
        }),
        new BinaryProbe("samtools", null, "samtools",
            List.of("--version"),
            line -> {
                String[] parts = line.split(" ", 2);
                return parts.length >= 2 ? parts[1] : line;
            }),
        new BinaryProbe("ThermoRawFileParser", "THERMORAWFILEPARSER",
            "ThermoRawFileParser", List.of("--help"),
            line -> "(present)"),
        new BinaryProbe("masslynxraw", "MASSLYNXRAW", "masslynxraw",
            List.of("--help"),
            line -> "(present)"),
        new BinaryProbe("Bruker Python helper", null, PYTHON_EXEC,
            List.of("-c", "import opentimspy; print(opentimspy.__version__)"),
            line -> "opentimspy " + line)
    );

    private static volatile List<ProbeResult> cache = List.of();

    /**
     * Listeners notified after every {@link #probeAll()} call. Used by
     * the Import / Export dialogs to re-render their format rows when
     * the user clicks Re-probe in the Diagnostics dialog.
     *
     * <p>{@link CopyOnWriteArrayList} keeps add / remove / iterate
     * thread-safe without a lock; listener counts are tiny (one or two
     * dialogs at a time), so the copy-on-write cost is negligible.</p>
     */
    private static final List<Runnable> CACHE_REFRESH_LISTENERS =
        new CopyOnWriteArrayList<>();

    private Diagnostics() {}

    /** Re-probe every registered dependency and refresh the cache.
     *  After the cache is updated, all registered cache-refresh listeners
     *  are invoked on the calling thread. */
    public static List<ProbeResult> probeAll() {
        cache = PROBES.stream().map(BinaryProbe::probe).toList();
        for (Runnable r : CACHE_REFRESH_LISTENERS) {
            try {
                r.run();
            } catch (RuntimeException ignored) {
                // Listener errors must not break the probe pipeline.
            }
        }
        return cache;
    }

    /** Register {@code listener} to be invoked after every successful
     *  {@link #probeAll()}. Idempotent if the same listener is added
     *  twice (no de-duplication on identity). */
    public static void addCacheRefreshListener(Runnable listener) {
        if (listener != null) CACHE_REFRESH_LISTENERS.add(listener);
    }

    /** De-register a previously {@linkplain #addCacheRefreshListener
     *  registered} listener. No-op if the listener was never registered. */
    public static void removeCacheRefreshListener(Runnable listener) {
        if (listener != null) CACHE_REFRESH_LISTENERS.remove(listener);
    }

    /** @return last {@link #probeAll()} result, or empty list before first probe. */
    public static List<ProbeResult> cached() {
        return cache;
    }

    /** @return {@code true} if a probe with the given name reported OK on the last run. */
    public static boolean isAvailable(String name) {
        return cached().stream().anyMatch(r ->
            r.name().equals(name) && r.status() == ProbeResult.Status.OK);
    }

    /** @return immutable view of the registered probes (mainly for tests/UI). */
    public static List<BinaryProbe> probes() {
        return PROBES;
    }
}
