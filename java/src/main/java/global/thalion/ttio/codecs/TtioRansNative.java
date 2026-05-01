/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * JNI bridge to libttio_rans native library.
 *
 * <p>Thread-safe. Methods marshal Java arrays to C, call the rANS kernels
 * (which dispatch to AVX2/SSE4.1/scalar at runtime), and return results.
 *
 * <p>Falls back gracefully: if the native library cannot be loaded
 * ({@link UnsatisfiedLinkError} on first call to {@code System.loadLibrary}),
 * {@link #isAvailable()} returns false and callers should use the pure-Java
 * implementation in {@link FqzcompNx16Z}.
 *
 * <p>This class is the Java analogue of the Python ctypes wrapper in
 * {@code python/src/ttio/codecs/fqzcomp_nx16_z.py}. The JNI C glue lives at
 * {@code native/src/ttio_rans_jni.c}; build it with
 * {@code cmake -DTTIO_RANS_BUILD_JNI=ON}.
 */
public final class TtioRansNative {
    private static final boolean LOADED;

    static {
        boolean ok = false;
        try {
            System.loadLibrary("ttio_rans_jni");
            ok = true;
        } catch (UnsatisfiedLinkError e) {
            // Library not on java.library.path; fall back to pure Java.
            ok = false;
        }
        LOADED = ok;
    }

    private TtioRansNative() {}

    /**
     * @return {@code true} if the native library was loaded successfully and
     *         the {@code encodeBlock}/{@code decodeBlock}/{@code kernelName}
     *         native methods are callable.
     */
    public static boolean isAvailable() { return LOADED; }

    /**
     * Encode a block of symbols via libttio_rans.
     *
     * @param symbols    raw symbols (0..255 each, treated as unsigned)
     * @param contexts   parallel context vector (one uint16 per symbol)
     * @param nContexts  total number of contexts (= freq.length)
     * @param freq       freq table, shape [nContexts][256]; entries must sum
     *                   to T = 4096 per context with no zero-frequency symbols
     *                   actually used
     * @param out        output buffer (caller-allocated, sized worst-case)
     * @param outLen     in/out single-element array: input is buffer capacity,
     *                   output is bytes actually written
     * @return TTIO_RANS_OK (0) or negative error code (TTIO_RANS_ERR_PARAM=-1,
     *         ERR_ALLOC=-2, ERR_CORRUPT=-3)
     */
    public static native int encodeBlock(
        byte[] symbols, short[] contexts, int nContexts,
        int[][] freq, byte[] out, int[] outLen);

    /**
     * Decode a block of symbols via libttio_rans.
     *
     * @param compressed encoded bytes (exactly the slice produced by encode;
     *                   no trailing slack)
     * @param contexts   parallel context vector (one uint16 per output symbol)
     * @param nContexts  total number of contexts
     * @param freq       freq table, shape [nContexts][256]
     * @param cum        cumulative table, shape [nContexts][256], where
     *                   cum[c][s] = sum_{s'<s} freq[c][s']
     * @param symbols    output buffer, length nSymbols, written in place
     * @param nSymbols   number of symbols to decode
     * @return TTIO_RANS_OK (0) or negative error code
     */
    public static native int decodeBlock(
        byte[] compressed, short[] contexts, int nContexts,
        int[][] freq, int[][] cum,
        byte[] symbols, int nSymbols);

    /**
     * @return Selected SIMD kernel name: "scalar", "sse4.1", or "avx2".
     *         Determined at library-load time by CPUID dispatch in
     *         {@code dispatch.c}.
     */
    public static native String kernelName();
}
