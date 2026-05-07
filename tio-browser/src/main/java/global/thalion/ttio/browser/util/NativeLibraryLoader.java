package global.thalion.ttio.browser.util;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Locale;

/**
 * Cross-platform loader for the {@code ttio_rans_jni} native library.
 *
 * <p>Resolution order on first call:</p>
 * <ol>
 *   <li>{@link System#loadLibrary(String)} — picks up a system-installed
 *       lib via {@code java.library.path} (developer mode).</li>
 *   <li>Resource extraction from {@code /native/<platformId>/...} bundled
 *       into the shaded jar by the GHA release workflow; copied to a
 *       temp file and loaded via {@link System#load(String)} (end-user
 *       fat-jar mode).</li>
 *   <li>Records {@link #lastError()}; the genomic UI surfaces this as a
 *       graceful-degradation placeholder so the rest of the app keeps
 *       working.</li>
 * </ol>
 *
 * <p>Idempotent — repeated calls are no-ops once {@link #isLoaded()}
 * returns {@code true} or {@link #lastError()} is set.</p>
 */
public final class NativeLibraryLoader {

    private static final Object LOCK = new Object();
    private static volatile boolean loaded = false;
    private static volatile Throwable lastError = null;
    private static volatile String resolvedFrom = "";

    private NativeLibraryLoader() {}

    public static void ensureRansJni() {
        if (loaded || lastError != null) return;
        synchronized (LOCK) {
            if (loaded || lastError != null) return;

            try {
                System.loadLibrary("ttio_rans_jni");
                loaded = true;
                resolvedFrom = "java.library.path";
                return;
            } catch (UnsatisfiedLinkError ignored) {
                // Fall through to bundled-resource path.
            }

            String pid = platformId();
            String resource = resourcePath(pid);
            if (resource == null) {
                lastError = new UnsupportedOperationException(
                    "no bundled libttio_rans_jni for platform " + pid);
                return;
            }

            try (InputStream in =
                     NativeLibraryLoader.class.getResourceAsStream(resource)) {
                if (in == null) {
                    lastError = new IOException(
                        "bundled native resource missing in jar: " + resource);
                    return;
                }
                Path tmp = Files.createTempFile(
                    "ttio_rans_jni-" + pid + "-", suffix(pid));
                tmp.toFile().deleteOnExit();
                Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
                System.load(tmp.toAbsolutePath().toString());
                loaded = true;
                resolvedFrom = "bundled:" + resource;
            } catch (IOException | UnsatisfiedLinkError e) {
                lastError = e;
            }
        }
    }

    public static boolean isLoaded() { return loaded; }
    public static Throwable lastError() { return lastError; }
    public static String resolvedFrom() { return resolvedFrom; }

    /** Visible for testing. */
    static String platformId() {
        return platformId(
            System.getProperty("os.name", ""),
            System.getProperty("os.arch", ""));
    }

    /** Visible for testing.
     *
     *  <p>macOS bundle is currently arm64-only (Apple Silicon). Intel
     *  Macs map to {@code "mac-x64"} which has no resource path —
     *  loader records {@link #lastError()} and the genomic Read
     *  Inspector falls back to a placeholder. Universal2 is a future
     *  follow-up gated on the SIMD .c files self-guarding for arm64.</p>
     */
    static String platformId(String osName, String osArch) {
        String os = osName == null ? "" : osName.toLowerCase(Locale.ROOT);
        String arch = osArch == null ? "" : osArch.toLowerCase(Locale.ROOT);
        if (os.contains("linux")) {
            return arch.contains("aarch64") || arch.contains("arm64")
                ? "linux-aarch64" : "linux-x64";
        }
        if (os.contains("mac") || os.contains("darwin")) {
            return arch.contains("aarch64") || arch.contains("arm64")
                ? "mac-aarch64" : "mac-x64";
        }
        if (os.contains("win")) {
            return arch.contains("aarch64") || arch.contains("arm64")
                ? "win-aarch64" : "win-x64";
        }
        return "unknown";
    }

    /** Visible for testing. */
    static String resourcePath(String pid) {
        return switch (pid) {
            case "linux-x64"     -> "/native/linux-x64/libttio_rans_jni.so";
            case "linux-aarch64" -> "/native/linux-aarch64/libttio_rans_jni.so";
            case "mac-aarch64"   -> "/native/mac-aarch64/libttio_rans_jni.dylib";
            case "win-x64"       -> "/native/win-x64/ttio_rans_jni.dll";
            case "win-aarch64"   -> "/native/win-aarch64/ttio_rans_jni.dll";
            default              -> null;
        };
    }

    private static String suffix(String pid) {
        if (pid.startsWith("linux")) return ".so";
        if (pid.startsWith("mac")) return ".dylib";
        if (pid.startsWith("win")) return ".dll";
        return ".bin";
    }
}
