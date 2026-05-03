/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Sanity test for the TtioRansNative.encodeV4 / decodeV4 JNI bridge.
 *
 * Verifies that a small synthetic input round-trips byte-exact through
 * the JNI marshaling. Catches obvious JNI bugs (wrong array width,
 * exception leakage, off-by-one in length passing) before the larger
 * dispatch tests in FqzcompNx16ZV4DispatchTest.
 *
 * Skipped automatically if libttio_rans_jni is not loaded.
 */
class TtioRansNativeV4Test {

    static boolean nativeAvailable() { return TtioRansNative.isAvailable(); }

    @Test
    @EnabledIf("nativeAvailable")
    void v4SmokeRoundtrip() {
        // 4 reads x 5 qualities = 20 bytes
        byte[] qualities = new byte[20];
        for (int i = 0; i < 20; i++) qualities[i] = (byte)(33 + (i * 7) % 40);
        int[] readLengths = {5, 5, 5, 5};
        int[] flags = {0, 16, 0, 0};  // SAM_REVERSE on read 1

        byte[] encoded = TtioRansNative.encodeV4(qualities, readLengths, flags,
                                                  /*strategyHint=*/-1, /*padCount=*/0);
        assertEquals('M', encoded[0]);
        assertEquals('9', encoded[1]);
        assertEquals('4', encoded[2]);
        assertEquals('Z', encoded[3]);
        assertEquals(4, encoded[4]);

        Object[] decoded = TtioRansNative.decodeV4(encoded, /*numReads=*/4,
                                                     /*numQualities=*/20, flags);
        byte[] qualBack = (byte[]) decoded[0];
        int[]  lensBack = (int[])  decoded[1];

        assertArrayEquals(qualities, qualBack);
        assertArrayEquals(readLengths, lensBack);
    }
}
