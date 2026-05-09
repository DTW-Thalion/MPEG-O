package global.thalion.ttio.browser.diag;

import java.util.List;
import java.util.Locale;

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

    private Diagnostics() {}

    /** Re-probe every registered dependency and refresh the cache. */
    public static List<ProbeResult> probeAll() {
        cache = PROBES.stream().map(BinaryProbe::probe).toList();
        return cache;
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
