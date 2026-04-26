/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Cross-language counterpart of
 *   python/tests/test_m85_quality.py
 *   objc/Tests/TestM85Quality.m
 *
 * <p>The canonical-vector fixtures under
 * {@code resources/ttio/codecs/quality_*.bin} are identical bytes
 * copied from the Python test fixtures; the Java encoder must
 * produce byte-for-byte identical output for the same inputs.
 */
final class QualityTest {

    /** Illumina-8 bin centres — same as in {@link Quality}. */
    private static final byte[] CENTRES = {0, 5, 15, 22, 27, 32, 37, 40};

    // ── Helpers ─────────────────────────────────────────────────────

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = QualityTest.class.getResourceAsStream(path)) {
            assertNotNull(in, "fixture missing on classpath: " + path);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        }
    }

    /** Mirror the Python bin-table mapping for expected lossy values. */
    private static byte expectedCentre(int phred) {
        int p = phred & 0xFF;
        int bin;
        if (p <= 1)        bin = 0;
        else if (p <= 9)   bin = 1;
        else if (p <= 19)  bin = 2;
        else if (p <= 24)  bin = 3;
        else if (p <= 29)  bin = 4;
        else if (p <= 34)  bin = 5;
        else if (p <= 39)  bin = 6;
        else               bin = 7;
        return CENTRES[bin];
    }

    private static byte[] vectorA() {
        byte[] data = new byte[256];
        for (int i = 0; i < 256; i++) {
            data[i] = CENTRES[i % 8];
        }
        return data;
    }

    private static byte[] vectorB() throws Exception {
        byte[] seedB = MessageDigest.getInstance("SHA-256")
            .digest("ttio-quality-vector-b".getBytes(StandardCharsets.UTF_8));
        byte[] data = new byte[1024];
        for (int i = 0; i < 1024; i++) {
            int s = Byte.toUnsignedInt(seedB[i % 32]);
            if (i < 512) {
                data[i] = (byte) (30 + (s % 11));
            } else {
                data[i] = (byte) (15 + (s % 16));
            }
        }
        return data;
    }

    private static byte[] vectorC() {
        return new byte[] {
            0,  1,
            2,  5,  9,
            10, 15, 19,
            20, 22, 24,
            25, 27, 29,
            30, 32, 34,
            35, 37, 39,
            40, 41, 50, 60, (byte) 93, (byte) 100, (byte) 200, (byte) 255,
            0, 5, 15, 22, 27, 32, 37, 40,
            0, 5, 15, 22, 27, 32, 37, 40,
            0, 5, 15, 22, 27, 32, 37, 40,
            0, 5, 15, 22, 27, 32, 37, 40,
            0, 5, 15, 22,
        };
    }

    // ── 1. Round-trip pure bin-centre bytes ────────────────────────

    @Test
    void roundTripPureCentreBytes() {
        byte[] data = new byte[256];
        for (int i = 0; i < 256; i++) {
            data[i] = CENTRES[i % 8];
        }
        byte[] enc = Quality.encode(data);
        // Header 6 + body ceil(256/2)=128 → 134.
        assertEquals(134, enc.length, "pure-centre encoded length");
        assertEquals((byte) 0x00, enc[0], "version byte");
        assertEquals((byte) 0x00, enc[1], "scheme_id");
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(data, dec, "pure-centre bytes round-trip exact");
    }

    // ── 2. Round-trip arbitrary Phred (lossy) ──────────────────────

    @Test
    void roundTripArbitraryPhred() {
        byte[] data = new byte[50];
        for (int i = 0; i < 50; i++) {
            data[i] = (byte) i;
        }
        byte[] expected = new byte[50];
        for (int i = 0; i < 50; i++) {
            expected[i] = expectedCentre(i);
        }
        byte[] enc = Quality.encode(data);
        // Header 6 + body ceil(50/2)=25 → 31.
        assertEquals(31, enc.length, "arbitrary-Phred encoded length");
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(expected, dec,
            "arbitrary Phred decodes to bin centres (lossy)");
    }

    // ── 3. Round-trip clamped (Phred 41+ → centre 40) ──────────────

    @Test
    void roundTripClamped() {
        byte[] data = new byte[] {
            (byte) 50, (byte) 60, (byte) 93,
            (byte) 100, (byte) 200, (byte) 255
        };
        byte[] enc = Quality.encode(data);
        // Header 6 + body ceil(6/2)=3 → 9.
        assertEquals(9, enc.length, "clamped encoded length");
        byte[] dec = Quality.decode(enc);
        assertEquals(6, dec.length, "clamped decoded length");
        for (int i = 0; i < 6; i++) {
            assertEquals((byte) 40, dec[i],
                "Phred " + Byte.toUnsignedInt(data[i]) + " saturates to 40");
        }
        // All bin indices are 7, so each body byte should be 0x77,
        // except the tail which has padding 0 in low nibble: 0x70.
        assertEquals((byte) 0x77, enc[6], "byte 0 = 0x77");
        assertEquals((byte) 0x77, enc[7], "byte 1 = 0x77");
        assertEquals((byte) 0x77, enc[8], "byte 2 = 0x77");
    }

    // ── 4. Round-trip empty ────────────────────────────────────────

    @Test
    void roundTripEmpty() {
        byte[] enc = Quality.encode(new byte[0]);
        assertEquals(6, enc.length, "empty encoded length = header only");
        assertEquals((byte) 0x00, enc[0], "version byte");
        assertEquals((byte) 0x00, enc[1], "scheme_id");
        for (int i = 2; i < 6; i++) {
            assertEquals((byte) 0x00, enc[i],
                "orig_len byte " + i + " must be zero");
        }
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(new byte[0], dec, "empty round-trip");
    }

    // ── 5. Round-trip single byte at each bin centre ───────────────

    @Test
    void roundTripSingleByte() {
        // Each bin centre encodes to a single body byte:
        // (bin_index << 4) | 0 (padding).
        for (int binIdx = 0; binIdx < 8; binIdx++) {
            byte centre = CENTRES[binIdx];
            byte[] data = new byte[] { centre };
            byte[] enc = Quality.encode(data);
            assertEquals(7, enc.length,
                "single-centre encoded length for centre " + (centre & 0xFF));
            byte expectedBody = (byte) ((binIdx & 0x0F) << 4);
            assertEquals(expectedBody, enc[6],
                "single-centre body byte for centre " + (centre & 0xFF));
            byte[] dec = Quality.decode(enc);
            assertArrayEquals(data, dec,
                "single-centre round-trip for centre " + (centre & 0xFF));
        }
    }

    // ── 6. Padding tail patterns ───────────────────────────────────

    @Test
    void paddingTailPatterns() {
        // 1-byte input b"\x05" (Phred 5 = bin 1, centre 5) → body 0x10.
        byte[] enc1 = Quality.encode(new byte[] { 5 });
        assertEquals(7, enc1.length, "1-byte encoded length");
        assertEquals((byte) 0x10, enc1[6], "1-byte body = 0x10");

        // 2-byte input b"\x05\x05" → body 0x11.
        byte[] enc2 = Quality.encode(new byte[] { 5, 5 });
        assertEquals(7, enc2.length, "2-byte encoded length");
        assertEquals((byte) 0x11, enc2[6], "2-byte body = 0x11");

        // 3-byte input b"\x05\x05\x05" → bodies 0x11 0x10.
        byte[] enc3 = Quality.encode(new byte[] { 5, 5, 5 });
        assertEquals(8, enc3.length, "3-byte encoded length");
        assertEquals((byte) 0x11, enc3[6], "3-byte body[0] = 0x11");
        assertEquals((byte) 0x10, enc3[7], "3-byte body[1] = 0x10");

        // 4-byte input b"\x05\x05\x05\x05" → bodies 0x11 0x11.
        byte[] enc4 = Quality.encode(new byte[] { 5, 5, 5, 5 });
        assertEquals(8, enc4.length, "4-byte encoded length");
        assertEquals((byte) 0x11, enc4[6], "4-byte body[0] = 0x11");
        assertEquals((byte) 0x11, enc4[7], "4-byte body[1] = 0x11");

        // Round-trips.
        assertArrayEquals(new byte[] { 5 },          Quality.decode(enc1));
        assertArrayEquals(new byte[] { 5, 5 },       Quality.decode(enc2));
        assertArrayEquals(new byte[] { 5, 5, 5 },    Quality.decode(enc3));
        assertArrayEquals(new byte[] { 5, 5, 5, 5 }, Quality.decode(enc4));
    }

    // ── 7. Compression ratio (1 MiB random Phred) ──────────────────

    @Test
    void compressionRatio() {
        int n = 1 << 20; // 1 MiB
        byte[] data = new byte[n];
        Random rng = new Random(0xC0DECABL);
        for (int i = 0; i < n; i++) {
            data[i] = (byte) (rng.nextInt(41));
        }
        byte[] enc = Quality.encode(data);
        // Header 6 + body ceil(1048576/2) = 524288 → 524294.
        assertEquals(6 + 524288, enc.length, "1 MiB encoded total");
        // Round-trip via lossy bin centres.
        byte[] expected = new byte[n];
        for (int i = 0; i < n; i++) {
            expected[i] = expectedCentre(data[i]);
        }
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(expected, dec, "1 MiB lossy round-trip");
    }

    // ── 8. Canonical vector A ──────────────────────────────────────

    @Test
    void canonicalVectorA() throws Exception {
        byte[] data = vectorA();
        assertEquals(256, data.length, "vector A length");
        byte[] enc = Quality.encode(data);
        byte[] fixture = loadFixture("quality_a.bin");
        assertEquals(134, fixture.length, "fixture A length");
        assertArrayEquals(fixture, enc, "vector A byte-exact");
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(data, dec, "vector A round-trip");
    }

    // ── 9. Canonical vector B ──────────────────────────────────────

    @Test
    void canonicalVectorB() throws Exception {
        byte[] data = vectorB();
        assertEquals(1024, data.length, "vector B length");
        byte[] enc = Quality.encode(data);
        byte[] fixture = loadFixture("quality_b.bin");
        assertEquals(518, fixture.length, "fixture B length");
        assertArrayEquals(fixture, enc, "vector B byte-exact");
        // Compute lossy-expected output for round-trip.
        byte[] expected = new byte[1024];
        for (int i = 0; i < 1024; i++) {
            expected[i] = expectedCentre(data[i]);
        }
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(expected, dec, "vector B lossy round-trip");
    }

    // ── 10. Canonical vector C ─────────────────────────────────────

    @Test
    void canonicalVectorC() throws Exception {
        byte[] data = vectorC();
        assertEquals(64, data.length, "vector C length");
        byte[] enc = Quality.encode(data);
        byte[] fixture = loadFixture("quality_c.bin");
        assertEquals(38, fixture.length, "fixture C length");
        assertArrayEquals(fixture, enc, "vector C byte-exact");
        byte[] expected = new byte[64];
        for (int i = 0; i < 64; i++) {
            expected[i] = expectedCentre(data[i]);
        }
        byte[] dec = Quality.decode(enc);
        assertArrayEquals(expected, dec, "vector C lossy round-trip");
    }

    // ── 11. Canonical vector D (empty) ─────────────────────────────

    @Test
    void canonicalVectorD() throws Exception {
        byte[] data = new byte[0];
        byte[] enc = Quality.encode(data);
        assertEquals(6, enc.length, "vector D = 6-byte header only");
        byte[] fixture = loadFixture("quality_d.bin");
        assertEquals(6, fixture.length, "fixture D length");
        assertArrayEquals(fixture, enc, "vector D byte-exact");
        assertArrayEquals(data, Quality.decode(enc), "vector D round-trip");
    }

    // ── 12. Decode malformed ───────────────────────────────────────

    @Test
    void decodeMalformed() {
        // (a) Stream shorter than the 6-byte header.
        byte[] tooShort = new byte[] { 0x00, 0x00, 0x00, 0x00, 0x00 };
        assertThrows(IllegalArgumentException.class,
            () -> Quality.decode(tooShort), "stream shorter than header");

        // Build a known-good stream as the basis for the rest:
        // orig_len=4 → body ceil(4/2)=2 → total 8.
        byte[] good = Quality.encode(new byte[] { 0, 5, 15, 22 });
        assertEquals(8, good.length, "good stream length");

        // (b) Bad version byte.
        byte[] badVer = good.clone();
        badVer[0] = 0x01;
        assertThrows(IllegalArgumentException.class,
            () -> Quality.decode(badVer), "bad version byte");

        // (c) Bad scheme_id.
        byte[] badScheme = good.clone();
        badScheme[1] = (byte) 0xFF;
        assertThrows(IllegalArgumentException.class,
            () -> Quality.decode(badScheme), "bad scheme_id");

        // (d) original_length says 4 but body is 5 bytes (extra byte).
        // Total would need to be 8 but stream has 9.
        byte[] tooLong = Arrays.copyOf(good, good.length + 1);
        assertThrows(IllegalArgumentException.class,
            () -> Quality.decode(tooLong),
            "orig_len=4 but body too long");

        // (e) original_length says 5 but body is only 2 bytes (truncation).
        // 5 → body ceil(5/2)=3, total expected 9. We supply 8.
        byte[] truncated = good.clone();
        // Patch orig_len to 5 (offset 2..5 BE).
        truncated[2] = 0x00;
        truncated[3] = 0x00;
        truncated[4] = 0x00;
        truncated[5] = 0x05;
        // Stream length stays 8 but expected total is 9 → mismatch.
        assertThrows(IllegalArgumentException.class,
            () -> Quality.decode(truncated),
            "orig_len=5 but body truncated");
    }

    // ── 13. Throughput ─────────────────────────────────────────────

    @Test
    void throughput() {
        int n = 4 * (1 << 20); // 4 MiB
        byte[] data = new byte[n];
        Random rng = new Random(0xBEEFL);
        for (int i = 0; i < n; i++) {
            data[i] = (byte) (rng.nextInt(41));
        }
        byte[] expected = new byte[n];
        for (int i = 0; i < n; i++) {
            expected[i] = expectedCentre(data[i]);
        }

        long t0 = System.nanoTime();
        byte[] enc = Quality.encode(data);
        long encDt = System.nanoTime() - t0;

        long t1 = System.nanoTime();
        byte[] dec = Quality.decode(enc);
        long decDt = System.nanoTime() - t1;

        double mib = (double) n / (1 << 20);
        double encMbS = mib / (encDt / 1e9);
        double decMbS = mib / (decDt / 1e9);
        System.out.printf(
            "%n  M85 throughput (4 MiB random Phred mod 41, Java): "
                + "encode %.2f MB/s, decode %.2f MB/s%n",
            encMbS, decMbS);

        assertEquals(6 + n / 2, enc.length, "throughput encoded total");
        assertArrayEquals(expected, dec, "throughput lossy round-trip");
        assertTrue(encMbS > 0.0, "encode throughput > 0");
        assertTrue(decMbS > 0.0, "decode throughput > 0");
    }
}
