package global.thalion.ttio.browser;

import java.nio.file.Path;

/**
 * Extracts and links the bundled HDF5 native libraries at startup so
 * the per-platform tio-browser shaded JAR works on a fresh machine
 * without any system HDF5 install.
 *
 * <p>Idempotent — safe to call from multiple entry points.
 *
 * <p>See {@code docs/superpowers/specs/2026-05-09-hdf5-bundled-natives-design.md}.
 */
public final class Hdf5NativeLoader {

    private static volatile boolean loaded = false;
    private static Path tempDir = null;

    private Hdf5NativeLoader() {}

    /**
     * Map JVM os.name + os.arch to one of the bundled platform classifiers
     * ({@code linux-x64}, {@code mac-aarch64}, {@code win-x64}). Returns
     * {@code null} if the running platform isn't bundled.
     *
     * <p>Package-private for unit-test access.
     */
    static String detectPlatform(String osName, String osArch) {
        String name = osName.toLowerCase();
        String arch = osArch.toLowerCase();
        if (name.contains("linux") && (arch.equals("amd64") || arch.equals("x86_64"))) {
            return "linux-x64";
        }
        if (name.contains("mac") && arch.equals("aarch64")) {
            return "mac-aarch64";
        }
        if (name.contains("windows") && (arch.equals("amd64") || arch.equals("x86_64"))) {
            return "win-x64";
        }
        return null;
    }

    /** Test seam: where the libs ended up. {@code null} until {@link #ensureLoaded()}. */
    public static Path tempDir() { return tempDir; }
}
