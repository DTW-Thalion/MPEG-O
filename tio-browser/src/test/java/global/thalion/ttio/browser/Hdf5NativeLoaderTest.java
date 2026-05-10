package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

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
}
