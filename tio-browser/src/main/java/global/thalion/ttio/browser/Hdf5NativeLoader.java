package global.thalion.ttio.browser;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
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

    private static final String[] LINUX_LIBS = {
        "libhdf5.so.310", "libhdf5_hl.so.310", "libhdf5_java.so", "libh5lz4.so"
    };
    private static final String[] MAC_LIBS = {
        "libhdf5.310.dylib", "libhdf5_hl.310.dylib", "libhdf5_java.dylib", "libh5lz4.dylib"
    };
    private static final String[] WIN_LIBS = {
        "hdf5.dll", "hdf5_hl.dll", "hdf5_java.dll", "h5lz4.dll"
    };

    /**
     * Extract bundled HDF5 native libs to a per-JVM temp dir, System.load
     * them in dependency order, register the LZ4 plugin search path. Idempotent.
     *
     * @throws Hdf5NativeLoadException on hard failures (unsupported platform,
     *   temp-dir creation failure, missing resource, UnsatisfiedLinkError on
     *   a core lib).
     */
    public static synchronized void ensureLoaded() {
        if (loaded) return;
        String platform = detectPlatform(
            System.getProperty("os.name"), System.getProperty("os.arch"));
        if (platform == null) {
            throw new Hdf5NativeLoadException(
                "Unsupported platform: " + System.getProperty("os.name") + " "
                + System.getProperty("os.arch") + ". Supported: linux-x64, "
                + "mac-aarch64, win-x64.");
        }
        String[] libs = libsFor(platform);
        Path dir;
        try {
            dir = Files.createTempDirectory("tio-browser-hdf5-");
        } catch (IOException e) {
            throw new Hdf5NativeLoadException(
                "Cannot create temp dir for HDF5 extraction. Set "
                + "java.io.tmpdir to a writable directory.", e);
        }
        Runtime.getRuntime().addShutdownHook(new Thread(() -> deleteRecursive(dir)));
        String resourcePrefix = "/native/" + platform + "/hdf5/";
        for (String lib : libs) {
            Path target = dir.resolve(lib);
            try (InputStream in = Hdf5NativeLoader.class.getResourceAsStream(resourcePrefix + lib)) {
                if (in == null) {
                    throw new Hdf5NativeLoadException(
                        "Resource missing from JAR: " + resourcePrefix + lib
                        + ". This JAR may be corrupt or built for the wrong "
                        + "platform — expected " + platform + ".");
                }
                Files.copy(in, target);
            } catch (IOException e) {
                throw new Hdf5NativeLoadException(
                    "Failed to extract " + lib + " to " + target, e);
            }
        }
        // Load core libs in dependency order: hdf5 -> hdf5_hl -> hdf5_java.
        // The LZ4 plugin (last entry in libs[]) is loaded by HDF5 itself
        // when the plugin path is registered (B.5 wires that); we don't
        // System.load it directly.
        for (int i = 0; i < libs.length - 1; i++) {
            Path lib = dir.resolve(libs[i]);
            try {
                System.load(lib.toAbsolutePath().toString());
            } catch (UnsatisfiedLinkError e) {
                throw new Hdf5NativeLoadException(
                    "Failed to System.load " + lib + ": " + e.getMessage(), e);
            }
        }
        tempDir = dir;
        // LZ4 plugin path registration lands in B.5.
        loaded = true;
    }

    private static String[] libsFor(String platform) {
        switch (platform) {
            case "linux-x64": return LINUX_LIBS;
            case "mac-aarch64": return MAC_LIBS;
            case "win-x64": return WIN_LIBS;
            default: throw new IllegalStateException("unreachable: " + platform);
        }
    }

    private static void deleteRecursive(Path dir) {
        try {
            if (!Files.exists(dir)) return;
            Files.walk(dir)
                 .sorted(java.util.Comparator.reverseOrder())
                 .forEach(p -> { try { Files.delete(p); } catch (IOException ignored) {} });
        } catch (IOException ignored) {}
    }

    /** Test seam: where the libs ended up. {@code null} until {@link #ensureLoaded()}. */
    public static Path tempDir() { return tempDir; }
}
