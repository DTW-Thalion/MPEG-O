package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;
import java.util.jar.JarEntry;
import java.util.jar.JarOutputStream;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class Hdf5NativeLoaderTest {

    @Test
    void detectPlatformLinuxX64() {
        assertEquals("linux-x64",
            Hdf5NativeLoader.detectPlatform("Linux", "amd64"));
        assertEquals("linux-x64",
            Hdf5NativeLoader.detectPlatform("Linux", "x86_64"));
    }

    @Test
    void detectPlatformMacAarch64() {
        assertEquals("mac-aarch64",
            Hdf5NativeLoader.detectPlatform("Mac OS X", "aarch64"));
    }

    @Test
    void detectPlatformWinX64() {
        assertEquals("win-x64",
            Hdf5NativeLoader.detectPlatform("Windows 10", "amd64"));
    }

    @Test
    void detectPlatformReturnsNullForUnsupported() {
        assertNull(Hdf5NativeLoader.detectPlatform("Mac OS X", "x86_64"));
        assertNull(Hdf5NativeLoader.detectPlatform("Linux", "aarch64"));
        assertNull(Hdf5NativeLoader.detectPlatform("FreeBSD", "amd64"));
    }

    @Test
    void ensureLoadedIsIdempotent() {
        Assumptions.assumeTrue(
            Hdf5NativeLoader.class.getResourceAsStream(
                "/native/linux-x64/hdf5/libhdf5.so.310") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/mac-aarch64/hdf5/libhdf5.310.dylib") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/win-x64/hdf5/hdf5.dll") != null,
            "no platform's HDF5 natives bundled in this build (Phase D wires it)");
        Hdf5NativeLoader.ensureLoaded();
        Path first = Hdf5NativeLoader.tempDir();
        Hdf5NativeLoader.ensureLoaded();
        Path second = Hdf5NativeLoader.tempDir();
        assertEquals(first, second);
    }

    @Test
    void ensureLoadedExtractsAllRequiredLibsForLinuxX64() throws Exception {
        Assumptions.assumeTrue(
            "linux-x64".equals(Hdf5NativeLoader.detectPlatform(
                System.getProperty("os.name"), System.getProperty("os.arch"))),
            "test only runs on linux-x64");
        Assumptions.assumeTrue(
            Hdf5NativeLoader.class.getResourceAsStream(
                "/native/linux-x64/hdf5/libhdf5.so.310") != null,
            "Linux HDF5 natives not bundled in this build (Phase D wires it)");
        Hdf5NativeLoader.ensureLoaded();
        Path tmp = Hdf5NativeLoader.tempDir();
        assertNotNull(tmp);
        assertTrue(Files.exists(tmp.resolve("libhdf5.so.310")));
        assertTrue(Files.exists(tmp.resolve("libhdf5_hl.so.310")));
        assertTrue(Files.exists(tmp.resolve("libhdf5_java.so")));
        assertTrue(Files.exists(tmp.resolve("libh5lz4.so")));
    }

    /**
     * Regression for issue #164: a JAR may contain files under a prefix
     * without an explicit ZIP directory entry for the prefix itself
     * (e.g. when re-packed via tools like {@code PowerShell
     * Compress-Archive}). The win-x64 enumeration path must not depend
     * on {@code getResource(prefix)} returning non-null — it must
     * bootstrap to the JarFile via a known-existing entry (a class file)
     * and iterate all entries to find the prefix matches.
     */
    @Test
    void jarEntriesUnderPrefixWorksWithoutDirectoryEntry(@TempDir Path tmp)
            throws Exception {
        Path jarPath = tmp.resolve("synthetic.jar");
        try (JarOutputStream jos = new JarOutputStream(Files.newOutputStream(jarPath))) {
            // Classfile-shaped probe entry (any non-empty content works
            // — Java doesn't validate magic when we read it as a resource).
            jos.putNextEntry(new JarEntry("a/Probe.class"));
            jos.write(new byte[] {(byte) 0xCA, (byte) 0xFE, (byte) 0xBA, (byte) 0xBE});
            jos.closeEntry();

            // Prefix-matching files — but DELIBERATELY NO directory entries
            // for native/, native/win-x64/, or native/win-x64/hdf5/.
            jos.putNextEntry(new JarEntry("native/win-x64/hdf5/hdf5.dll"));
            jos.write("fake hdf5".getBytes());
            jos.closeEntry();

            jos.putNextEntry(new JarEntry("native/win-x64/hdf5/libwinpthread-1.dll"));
            jos.write("fake pthread".getBytes());
            jos.closeEntry();

            // Decoy: a file matching the prefix but not a .dll — the
            // caller filters these out, but jarEntriesUnderPrefix should
            // still return it.
            jos.putNextEntry(new JarEntry("native/win-x64/hdf5/README.txt"));
            jos.write("note".getBytes());
            jos.closeEntry();

            // Decoy: a file under a sibling prefix that must NOT match.
            jos.putNextEntry(new JarEntry("native/linux-x64/hdf5/libhdf5.so.310"));
            jos.write("nope".getBytes());
            jos.closeEntry();
        }

        // Sanity: confirm the JAR really lacks a directory entry for the
        // prefix — that's the precondition this regression test is
        // proving the loader survives.
        URL prefixUrl = new URI("jar:" + jarPath.toUri() + "!/native/win-x64/hdf5/").toURL();
        try (java.util.jar.JarFile jar = new java.util.jar.JarFile(jarPath.toFile())) {
            assertNull(jar.getEntry("native/win-x64/hdf5/"),
                "test precondition: synthetic JAR has no directory entry");
            assertNotNull(jar.getEntry("native/win-x64/hdf5/hdf5.dll"),
                "test precondition: file entry under the prefix IS present");
        }

        URL probeUrl = new URI("jar:" + jarPath.toUri() + "!/a/Probe.class").toURL();
        List<JarEntry> entries = Hdf5NativeLoader.jarEntriesUnderPrefix(
            probeUrl, "native/win-x64/hdf5/");

        Set<String> names = entries.stream()
            .map(JarEntry::getName).collect(Collectors.toSet());
        assertEquals(3, entries.size(),
            "expected 3 file entries under the prefix; got: " + names);
        assertTrue(names.contains("native/win-x64/hdf5/hdf5.dll"));
        assertTrue(names.contains("native/win-x64/hdf5/libwinpthread-1.dll"));
        assertTrue(names.contains("native/win-x64/hdf5/README.txt"));
        // Confirm the sibling-prefix decoy was correctly excluded:
        assertTrue(!names.contains("native/linux-x64/hdf5/libhdf5.so.310"));
    }

    /**
     * Exploded-classpath case: when the probe URL isn't a {@code jar:}
     * URL (running from {@code target/classes/} under {@code mvn test}),
     * the JAR enumeration returns an empty list — not an error. The
     * runtime path under exploded classpath doesn't need to extract the
     * MinGW closure (no JAR to extract it from), so an empty list is
     * the correct "nothing to do" signal.
     */
    @Test
    void jarEntriesUnderPrefixReturnsEmptyForExplodedClasspath() throws Exception {
        // The Hdf5NativeLoader class itself, when running under
        // `mvn test`, is loaded from a `file:` URL pointing at the
        // exploded class tree under target/classes/.
        URL classUrl = Hdf5NativeLoader.class.getResource(
            "/" + Hdf5NativeLoader.class.getName().replace('.', '/') + ".class");
        assertNotNull(classUrl, "own class resource must be findable");
        // Under exploded classpath this is a file: URL; under a packaged
        // JAR (e.g. when the test runs against an already-shaded artifact)
        // it would be jar:. Either way, the result is well-defined.
        if ("file".equals(classUrl.getProtocol())) {
            assertEquals(List.of(),
                Hdf5NativeLoader.jarEntriesUnderPrefix(
                    classUrl, "native/win-x64/hdf5/"));
        }
    }
}
