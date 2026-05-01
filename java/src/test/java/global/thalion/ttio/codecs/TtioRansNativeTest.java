/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests for {@link TtioRansNative} JNI bridge and {@link FqzcompNx16Z#getBackendName()}.
 *
 * <p>The native-roundtrip and kernel-name tests are conditional on the
 * {@code libttio_rans_jni} shared library being on {@code java.library.path}
 * — they pass trivially when the library is absent so existing CI without
 * the native build keeps working.
 *
 * <p>To exercise the native path, build the C library with
 * {@code cmake -DTTIO_RANS_BUILD_JNI=ON} and pass
 * {@code -Djava.library.path=<dir>} to Maven, e.g.
 * <pre>
 *     mvn test -Djava.library.path=$HOME/TTI-O/native/_build
 * </pre>
 */
final class TtioRansNativeTest {

    @Test
    void backendIsAtLeastPureJava() {
        String backend = FqzcompNx16Z.getBackendName();
        assertNotNull(backend, "backend name must not be null");
        assertTrue(
            backend.equals("pure-java")
                || backend.equals("native")
                || backend.startsWith("native-"),
            "unexpected backend name: " + backend);
    }

    @Test
    void nativeRoundtripIfAvailable() {
        if (!TtioRansNative.isAvailable()) {
            return; // Native library not on java.library.path; skip silently.
        }

        // Simple round-trip: 8 symbols from a uniform 4-symbol alphabet.
        // freq must sum to T = 4096 per context (CRAM-Nx16 discipline).
        byte[] symbols = {0, 1, 2, 3, 0, 1, 2, 3};
        short[] contexts = {0, 0, 0, 0, 0, 0, 0, 0};
        int[][] freq = new int[1][256];
        freq[0][0] = freq[0][1] = freq[0][2] = freq[0][3] = 1024;
        int[][] cum = new int[1][256];
        // cum[c][s] = sum_{s'<s} freq[c][s']; for s>=4, all-zero rows mean
        // cum stays at 4096 (= T), but those entries are never indexed since
        // no symbol >= 4 appears in the input.
        cum[0][0] = 0;
        cum[0][1] = 1024;
        cum[0][2] = 2048;
        cum[0][3] = 3072;
        for (int s = 4; s < 256; s++) cum[0][s] = 4096;

        byte[] out = new byte[256];
        int[] outLen = {out.length};
        int rc = TtioRansNative.encodeBlock(
            symbols, contexts, 1, freq, out, outLen);
        assertEquals(0, rc, "encode rc");
        assertTrue(outLen[0] > 0, "encoded length must be positive");

        byte[] compressed = java.util.Arrays.copyOf(out, outLen[0]);
        byte[] dec = new byte[symbols.length];
        rc = TtioRansNative.decodeBlock(
            compressed, contexts, 1, freq, cum, dec, symbols.length);
        assertEquals(0, rc, "decode rc");
        assertArrayEquals(symbols, dec, "round-trip must reproduce symbols");
    }

    @Test
    void kernelNameIfAvailable() {
        if (!TtioRansNative.isAvailable()) {
            return; // Native library not on java.library.path; skip silently.
        }
        String name = TtioRansNative.kernelName();
        assertNotNull(name, "kernel name must not be null");
        assertTrue(
            name.equals("scalar")
                || name.equals("sse4.1")
                || name.equals("avx2"),
            "unexpected kernel: " + name);
    }

    @Test
    void backendNameMatchesAvailability() {
        String backend = FqzcompNx16Z.getBackendName();
        if (TtioRansNative.isAvailable()) {
            assertTrue(backend.startsWith("native"),
                "loaded library must report native backend, got: " + backend);
        } else {
            assertEquals("pure-java", backend,
                "without native library, backend must be pure-java");
        }
    }
}
