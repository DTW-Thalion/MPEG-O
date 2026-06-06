/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.nio.charset.StandardCharsets;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * FQZCOMP_NX16.Z unit tests — Java parity for the M94.Z (CRAM-mimic) codec.
 *
 * <p>Mirrors {@code FqzcompNx16UnitTest} but for the M94.Z codec. The
 * 7 canonical fixtures (a..d, f..h) are byte-exact across Python /
 * Cython / Java.
 */
final class FqzcompNx16ZUnitTest {

    /** Matches @EnabledIf signature: a no-arg method returning boolean. */
    static boolean isNativeAvailable() {
        return TtioRansNative.isAvailable();
    }

    // ── Constants ──────────────────────────────────────────────────

    @Test
    void constantsMatchSpec() {
        // Wire-format version constants (the dispatch + legacy-rejection
        // surface). VERSION / VERSION_V2_NATIVE are retained only so
        // decode() can recognise and reject legacy streams.
        assertEquals(1, FqzcompNx16Z.VERSION);
        assertEquals(2, FqzcompNx16Z.VERSION_V2_NATIVE);
        assertEquals(4, FqzcompNx16Z.VERSION_V4_FQZCOMP);
    }

    @Test
    void magicIsM94Z() {
        assertEquals('M', FqzcompNx16Z.MAGIC[0]);
        assertEquals('9', FqzcompNx16Z.MAGIC[1]);
        assertEquals('4', FqzcompNx16Z.MAGIC[2]);
        assertEquals('Z', FqzcompNx16Z.MAGIC[3]);
        assertEquals(1, FqzcompNx16Z.VERSION);
    }

    // ── Round-trip smoke tests ──────────────────────────────────────
    // Phase 2c: encode() requires the native libttio_rans library
    // (only V4 is emitted in v1.0+); these tests are JNI-gated.

    @Test
    @EnabledIf("isNativeAvailable")
    void roundTripAllQ40Smoke() {
        byte[] qualities = "IIIIIIIIII".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {10};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16Z.encode(qualities, readLengths, revcomp);
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
        assertArrayEquals(readLengths, dec.readLengths());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void roundTripSingleByte() {
        byte[] qualities = "I".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {1};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16Z.encode(qualities, readLengths, revcomp);
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void roundTripPaddingNonMultipleOf4() {
        byte[] qualities = "IIIII".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {5};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16Z.encode(qualities, readLengths, revcomp);
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void roundTripMultiReadVaried() {
        byte[] qualities = ("AAAAAAAAAA"
                          + "BBBBBBBBBB"
                          + "CCCCCCCCCC").getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {10, 10, 10};
        int[] revcomp = {0, 1, 0};
        byte[] enc = FqzcompNx16Z.encode(qualities, readLengths, revcomp);
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
        assertArrayEquals(readLengths, dec.readLengths());
    }

    @Test
    void unpackRejectsBadMagic() {
        byte[] bad = new byte[64];
        bad[0] = 'X'; bad[1] = 'X'; bad[2] = 'X'; bad[3] = 'X';
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16Z.decode(bad, null));
    }

    // The legacy V1 canonical fixtures (m94z_*.bin) and their builders were
    // removed alongside the dead V1/V2 codec paths. V4 (CRAM 3.1
    // fqzcomp_qual) byte-exact coverage lives in FqzcompNx16ZV4ByteExactTest;
    // live-path edge/error coverage lives in FqzcompNx16ZV4DispatchTest.
}
