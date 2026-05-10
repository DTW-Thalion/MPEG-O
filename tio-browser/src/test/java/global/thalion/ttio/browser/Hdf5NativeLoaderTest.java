package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

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
}
