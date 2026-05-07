package global.thalion.ttio.browser.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class NativeLibraryLoaderTest {

    @Test
    void platformIdRecognizesLinuxX64() {
        assertEquals("linux-x64",
            NativeLibraryLoader.platformId("Linux", "amd64"));
        assertEquals("linux-x64",
            NativeLibraryLoader.platformId("Linux", "x86_64"));
    }

    @Test
    void platformIdRecognizesLinuxAarch64() {
        assertEquals("linux-aarch64",
            NativeLibraryLoader.platformId("Linux", "aarch64"));
    }

    @Test
    void platformIdRecognizesMacArches() {
        // Bundle ships arm64-only; mac-x64 has no resource (Intel-Mac
        // users hit graceful degradation).
        assertEquals("mac-x64",
            NativeLibraryLoader.platformId("Mac OS X", "x86_64"));
        assertEquals("mac-aarch64",
            NativeLibraryLoader.platformId("Mac OS X", "aarch64"));
        assertEquals("mac-aarch64",
            NativeLibraryLoader.platformId("Darwin", "arm64"));
    }

    @Test
    void platformIdRecognizesWindows() {
        assertEquals("win-x64",
            NativeLibraryLoader.platformId("Windows 10", "amd64"));
        assertEquals("win-aarch64",
            NativeLibraryLoader.platformId("Windows 11", "aarch64"));
    }

    @Test
    void platformIdReturnsUnknownForExotic() {
        assertEquals("unknown",
            NativeLibraryLoader.platformId("FreeBSD", "amd64"));
    }

    @Test
    void resourcePathMatchesShadeLayout() {
        assertEquals("/native/linux-x64/libttio_rans_jni.so",
            NativeLibraryLoader.resourcePath("linux-x64"));
        assertEquals("/native/mac-aarch64/libttio_rans_jni.dylib",
            NativeLibraryLoader.resourcePath("mac-aarch64"));
        assertEquals("/native/win-x64/ttio_rans_jni.dll",
            NativeLibraryLoader.resourcePath("win-x64"));
        // Intel Mac has no bundled native (graceful degradation).
        assertNull(NativeLibraryLoader.resourcePath("mac-x64"));
        assertNull(NativeLibraryLoader.resourcePath("unknown"));
    }
}
