package global.thalion.ttio.browser;

import java.io.IOException;
import java.io.InputStream;
import java.net.JarURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.stream.Collectors;
import java.util.stream.Stream;

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

    // Per-platform "core" HDF5 libs that MUST be loaded via System.load.
    // On Windows, the JAR also contains bundled MinGW runtime DLL deps
    // (libwinpthread-1.dll, libgcc_s_seh-1.dll, libcurl-4.dll, etc.)
    // discovered at runtime via the JAR's resource directory listing —
    // they're not enumerated here because the set varies with what the
    // build runner's HDF5 + LZ4 plugin actually link against.
    //
    // The last entry in each array is the LZ4 plugin (h5lz4.*), which is
    // NOT System.load'd directly: HDF5 lazy-loads it when reading LZ4-
    // compressed data, via the plugin path registered with H5PLprepend.
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
     * <p>On Windows, the JAR also contains the MinGW runtime DLL closure
     * (libwinpthread-1.dll, libgcc_s_seh-1.dll, libcurl-4.dll, etc.) that
     * the HDF5 DLLs link against. Windows' standard LoadLibrary search
     * order does NOT include the loaded DLL's directory for dependencies,
     * so every dep has to be System.load'd by full path BEFORE the DLL
     * that needs it. A multi-pass loop handles unknown dep order —
     * retrying failures until all loads succeed or no further progress
     * is possible.
     *
     * @throws Hdf5NativeLoadException on hard failures (unsupported platform,
     *   temp-dir creation failure, missing resource, or DLL load failures
     *   that don't resolve across passes).
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
        String[] coreLibs = libsFor(platform);
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

        // Extract core libs (always present, named per-platform).
        for (String lib : coreLibs) {
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

        // On Windows, also extract every additional bundled DLL (the MinGW
        // runtime closure). Linux + macOS have proper rpath / @rpath
        // baked into their HL libs so the dynamic linker finds them in
        // the same directory; Windows doesn't, so we must extract and
        // pre-load them.
        if ("win-x64".equals(platform)) {
            extractAllBundledWinDlls(dir, resourcePrefix, coreLibs);
        }

        // Multi-pass System.load: try every extracted DLL; on
        // UnsatisfiedLinkError (missing dep not yet loaded), skip and
        // retry next pass. Once a dep is loaded by full path, Windows
        // caches it by basename, so DLLs that import it by name will
        // resolve on subsequent passes. Skip the LZ4 plugin (last entry
        // in coreLibs) — HDF5 lazy-loads that via the plugin path.
        String pluginLib = coreLibs[coreLibs.length - 1];
        List<Path> toLoad;
        try (Stream<Path> s = Files.list(dir)) {
            toLoad = s.filter(p -> {
                       String n = p.getFileName().toString();
                       return n.endsWith(".dll") || n.endsWith(".so")
                           || n.contains(".so.") || n.endsWith(".dylib");
                   })
                   .filter(p -> !p.getFileName().toString().equals(pluginLib))
                   .collect(Collectors.toList());
        } catch (IOException e) {
            throw new Hdf5NativeLoadException("Could not list temp dir " + dir, e);
        }

        Set<Path> loadedSet = new HashSet<>();
        int maxPasses = toLoad.size() + 1;
        UnsatisfiedLinkError lastError = null;
        while (loadedSet.size() < toLoad.size() && maxPasses-- > 0) {
            boolean progress = false;
            for (Path p : toLoad) {
                if (loadedSet.contains(p)) continue;
                try {
                    System.load(p.toAbsolutePath().toString());
                    loadedSet.add(p);
                    progress = true;
                } catch (UnsatisfiedLinkError e) {
                    lastError = e;
                    // try again next pass
                }
            }
            if (!progress) break;
        }
        if (loadedSet.size() < toLoad.size()) {
            List<String> notLoaded = toLoad.stream()
                .filter(p -> !loadedSet.contains(p))
                .map(p -> p.getFileName().toString())
                .collect(Collectors.toList());
            throw new Hdf5NativeLoadException(
                "Could not load all bundled HDF5 native libs after "
                + (toLoad.size() + 1) + " passes. Still failing: " + notLoaded
                + ". Last error: " + (lastError != null ? lastError.getMessage() : "n/a"),
                lastError);
        }

        tempDir = dir;

        // Tell JHI5 (jarhdf5) the absolute path to hdf5_java so its class
        // static initializer uses System.load(path) instead of
        // System.loadLibrary("hdf5_java"). The JVM tracks loaded libraries
        // by absolute path, NOT basename — so our earlier System.load of
        // the extracted hdf5_java.dll is not seen by JHI5's
        // System.loadLibrary call, and JHI5 fails with
        // "no hdf5_java in java.library.path". Setting this property
        // before any access to the H5 class bypasses the loadLibrary
        // path entirely. Property name comes from JHI5's
        // H5.H5PATH_PROPERTY_KEY ("hdf.hdf5lib.H5.hdf5lib").
        String h5javaName = libsFor(platform)[2]; // hdf5_java.* per platform
        Path h5javaPath = dir.resolve(h5javaName).toAbsolutePath();
        System.setProperty("hdf.hdf5lib.H5.hdf5lib", h5javaPath.toString());

        // Register the LZ4 plugin search path with JHI5. H5PLprepend (not
        // append) so our temp dir takes precedence over HDF5's compile-time
        // default plugin path (which is the build runner's MSYS2 location
        // and doesn't exist on user machines).
        try {
            hdf.hdf5lib.H5.H5PLprepend(dir.toAbsolutePath().toString());
        } catch (Throwable t) {
            java.util.logging.Logger.getLogger(Hdf5NativeLoader.class.getName())
                .warning("Could not register LZ4 plugin path: " + t.getMessage()
                    + " (LZ4-compressed datasets won't open, but other features work)");
        }
        loaded = true;
    }

    /**
     * Extract every {@code .dll} resource under the given prefix that
     * isn't already accounted for by the core libs list. Used on Windows
     * to extract the MinGW runtime DLL closure bundled by the release
     * workflow's "Stage natives" step.
     *
     * <p>Locates the JAR via this class's own {@code .class} resource
     * (always a JAR entry, regardless of whether maven-shade-plugin
     * emitted a directory entry for the native/ prefix). Iterating the
     * JAR's full entry list and filtering by prefix is robust against
     * ZIPs lacking the directory entry — see TTI-O issue #164 (the v1.4.1
     * release JARs were repacked via tools that omit directory entries,
     * and the prior implementation's {@code getResource(prefix)} bootstrap
     * returned null on those).
     */
    private static void extractAllBundledWinDlls(Path dir, String resourcePrefix,
                                                 String[] coreLibs) {
        Set<String> core = new HashSet<>(Arrays.asList(coreLibs));
        String entryPrefix = resourcePrefix.startsWith("/")
            ? resourcePrefix.substring(1) : resourcePrefix;

        // Bootstrap to the containing JarFile via the class's own .class
        // resource — guaranteed to be a JarFile entry, no dependency on
        // whether the maven-shade-plugin chose to emit a directory entry
        // for the native/win-x64/hdf5/ prefix.
        String classResource = "/" + Hdf5NativeLoader.class.getName()
                                     .replace('.', '/') + ".class";
        URL classUrl = Hdf5NativeLoader.class.getResource(classResource);
        if (classUrl == null) {
            throw new Hdf5NativeLoadException(
                "Cannot locate own class resource: " + classResource);
        }
        try {
            for (JarEntry entry : jarEntriesUnderPrefix(classUrl, entryPrefix)) {
                String base = entry.getName().substring(entryPrefix.length());
                if (!base.endsWith(".dll")) continue;
                if (core.contains(base)) continue;  // already extracted
                Path target = dir.resolve(base);
                URLConnection conn = classUrl.openConnection();
                JarFile jar = ((JarURLConnection) conn).getJarFile();
                try (InputStream in = jar.getInputStream(entry)) {
                    Files.copy(in, target);
                }
            }
        } catch (IOException e) {
            throw new Hdf5NativeLoadException(
                "Failed to enumerate bundled win-x64 DLLs from JAR", e);
        }
    }

    /**
     * List every {@link JarEntry} under {@code entryPrefix} in the JAR
     * containing the resource at {@code probeUrl}. Filters out directory
     * entries; returns an empty list if the probe is not a {@code
     * jar:file:...!/...} URL (e.g. when running from an exploded
     * classpath in unit tests / the IDE).
     *
     * <p>Robust against JARs that lack a directory entry for the prefix
     * itself (the root-cause behaviour fixed for issue #164 — repackers
     * like {@code PowerShell Compress-Archive} omit those entries, and
     * the prior implementation's {@code getResource(prefix)} bootstrap
     * returned null on such JARs).
     *
     * <p>Package-private for unit-test access.
     */
    static List<JarEntry> jarEntriesUnderPrefix(URL probeUrl, String entryPrefix)
            throws IOException {
        URLConnection conn = probeUrl.openConnection();
        if (!(conn instanceof JarURLConnection)) return List.of();
        JarFile jar = ((JarURLConnection) conn).getJarFile();
        List<JarEntry> result = new ArrayList<>();
        Enumeration<JarEntry> entries = jar.entries();
        while (entries.hasMoreElements()) {
            JarEntry entry = entries.nextElement();
            String name = entry.getName();
            if (!name.startsWith(entryPrefix) || entry.isDirectory()) continue;
            result.add(entry);
        }
        return result;
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
