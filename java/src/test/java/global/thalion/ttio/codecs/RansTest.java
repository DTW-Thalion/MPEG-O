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
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Cross-language counterpart of
 *   python/tests/test_m83_rans.py
 *   objc/Tests/TestM83Rans.m
 *
 * <p>The canonical-vector fixtures under
 * {@code resources/ttio/codecs/rans_*.bin} are identical bytes copied
 * from the Python test fixtures; the Java encoder must produce
 * byte-for-byte identical output for the same inputs.
 */
final class RansTest {

    // ── Helpers ─────────────────────────────────────────────────────

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = RansTest.class.getResourceAsStream(path)) {
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

    private static byte[] vectorA() throws NoSuchAlgorithmException {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest("ttio-rans-test-vector-a".getBytes());
        byte[] out = new byte[digest.length * 8];
        for (int i = 0; i < 8; i++) {
            System.arraycopy(digest, 0, out, i * digest.length, digest.length);
        }
        return out;
    }

    private static byte[] vectorB() {
        byte[] data = new byte[1024];
        Arrays.fill(data, 0, 800, (byte) 0);
        Arrays.fill(data, 800, 900, (byte) 1);
        Arrays.fill(data, 900, 980, (byte) 2);
        Arrays.fill(data, 980, 1024, (byte) 3);
        return data;
    }

    private static byte[] vectorC() {
        byte[] data = new byte[512];
        for (int i = 0; i < 512; i++) {
            data[i] = (byte) (i % 4);
        }
        return data;
    }

    private static byte[] biasedPayload1MB() {
        int n = 1 << 20;
        byte[] data = new byte[n];
        int c0 = (int) (n * 0.90); // 943718
        int c1 = (int) (n * 0.05); // 52428
        int c2 = (int) (n * 0.03); // 31457
        int idx = 0;
        Arrays.fill(data, idx, idx + c0, (byte) 0x00);
        idx += c0;
        Arrays.fill(data, idx, idx + c1, (byte) 0x01);
        idx += c1;
        Arrays.fill(data, idx, idx + c2, (byte) 0x02);
        idx += c2;
        Arrays.fill(data, idx, n, (byte) 0x03);
        return data;
    }

    // ── 1. Round-trip random order-0 ────────────────────────────────

    @Test
    void roundTripOrder0Random() {
        byte[] data = new byte[1 << 20];
        new SecureRandom().nextBytes(data);
        byte[] enc = Rans.encode(data, 0);
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "order-0 random 1 MB round-trip");
        // Random data is essentially incompressible.
        assertTrue(enc.length >= data.length,
            "random order-0 enc=" + enc.length + " < input=" + data.length);
        // Header + freq table is present.
        assertEquals(0, enc[0], "order byte must be 0");
    }

    // ── 2. Round-trip random order-1 ────────────────────────────────

    @Test
    void roundTripOrder1Random() {
        byte[] data = new byte[1 << 20];
        new SecureRandom().nextBytes(data);
        byte[] enc = Rans.encode(data, 1);
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "order-1 random 1 MB round-trip");
        assertEquals(1, enc[0], "order byte must be 1");
    }

    // ── 3. Round-trip biased order-0 ────────────────────────────────

    @Test
    void roundTripOrder0Biased() {
        byte[] data = biasedPayload1MB();
        assertEquals(1 << 20, data.length, "biased payload length");
        byte[] enc = Rans.encode(data, 0);
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "order-0 biased round-trip");
        assertTrue(enc.length < data.length / 2,
            "biased order-0 enc=" + enc.length + " >= half input");
    }

    // ── 4. Round-trip biased order-1 ────────────────────────────────

    @Test
    void roundTripOrder1Biased() {
        byte[] data = biasedPayload1MB();
        byte[] enc0 = Rans.encode(data, 0);
        byte[] enc1 = Rans.encode(data, 1);
        byte[] dec1 = Rans.decode(enc1);
        assertArrayEquals(data, dec1, "order-1 biased round-trip");
        assertTrue(enc1.length <= enc0.length,
            "order-1 (" + enc1.length + ") should not exceed order-0 (" + enc0.length + ")");
    }

    // ── 5. Round-trip all-identical ─────────────────────────────────

    @Test
    void roundTripAllIdentical() {
        byte[] data = new byte[1 << 20];
        Arrays.fill(data, (byte) 0x41);
        byte[] enc = Rans.encode(data, 0);
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "all-identical round-trip");
        assertTrue(enc.length < 10 * 1024,
            "all-identical enc=" + enc.length + " >= 10 KiB");
    }

    // ── 6. Round-trip empty ─────────────────────────────────────────

    @Test
    void roundTripEmpty() {
        for (int order : new int[]{0, 1}) {
            byte[] enc = Rans.encode(new byte[0], order);
            byte[] dec = Rans.decode(enc);
            assertArrayEquals(new byte[0], dec, "empty round-trip order=" + order);
            // Original length field is 0, payload still has 4-byte initial state.
            assertEquals(order, enc[0] & 0xFF, "order byte for empty stream");
            int origLen = ((enc[1] & 0xFF) << 24) | ((enc[2] & 0xFF) << 16)
                | ((enc[3] & 0xFF) << 8) | (enc[4] & 0xFF);
            int payloadLen = ((enc[5] & 0xFF) << 24) | ((enc[6] & 0xFF) << 16)
                | ((enc[7] & 0xFF) << 8) | (enc[8] & 0xFF);
            assertEquals(0, origLen, "empty original_length");
            assertEquals(4, payloadLen, "empty payload is just bootstrap state");
        }
    }

    // ── 7. Round-trip single byte ───────────────────────────────────

    @Test
    void roundTripSingleByte() {
        for (int order : new int[]{0, 1}) {
            byte[] data = new byte[]{0x42};
            byte[] enc = Rans.encode(data, order);
            byte[] dec = Rans.decode(enc);
            assertArrayEquals(data, dec, "single byte round-trip order=" + order);
        }
    }

    // ── 8. Canonical vector A order-0 ───────────────────────────────

    @Test
    void canonicalVectorAOrder0() throws Exception {
        byte[] data = vectorA();
        assertEquals(256, data.length, "vector A length");
        byte[] enc = Rans.encode(data, 0);
        byte[] fixture = loadFixture("rans_a_o0.bin");
        assertArrayEquals(fixture, enc, "vector A order-0 byte-exact");
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "vector A order-0 round-trip");
    }

    // ── 9. Canonical vector A order-1 ───────────────────────────────

    @Test
    void canonicalVectorAOrder1() throws Exception {
        byte[] data = vectorA();
        byte[] enc = Rans.encode(data, 1);
        byte[] fixture = loadFixture("rans_a_o1.bin");
        assertArrayEquals(fixture, enc, "vector A order-1 byte-exact");
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "vector A order-1 round-trip");
    }

    // ── 10. Canonical vector B order-0 ──────────────────────────────

    @Test
    void canonicalVectorBOrder0() throws Exception {
        byte[] data = vectorB();
        assertEquals(1024, data.length, "vector B length");
        byte[] enc = Rans.encode(data, 0);
        byte[] fixture = loadFixture("rans_b_o0.bin");
        assertArrayEquals(fixture, enc, "vector B order-0 byte-exact");
        byte[] dec = Rans.decode(enc);
        assertArrayEquals(data, dec, "vector B order-0 round-trip");
        // Payload (rANS bytes after header + freq table) < 300 B.
        int payloadLen = ((enc[5] & 0xFF) << 24) | ((enc[6] & 0xFF) << 16)
            | ((enc[7] & 0xFF) << 8) | (enc[8] & 0xFF);
        assertTrue(payloadLen < 300, "vector B order-0 payload=" + payloadLen + " bytes");
    }

    // ── 11. Canonical vector B order-1 ──────────────────────────────

    @Test
    void canonicalVectorBOrder1() throws Exception {
        byte[] data = vectorB();
        byte[] enc = Rans.encode(data, 1);
        byte[] fixture = loadFixture("rans_b_o1.bin");
        assertArrayEquals(fixture, enc, "vector B order-1 byte-exact");
        assertArrayEquals(data, Rans.decode(enc), "vector B order-1 round-trip");
    }

    // ── 12. Canonical vector C — order-0 vs order-1 ─────────────────

    @Test
    void canonicalVectorCOrder0VsOrder1() throws Exception {
        byte[] data = vectorC();
        assertEquals(512, data.length, "vector C length");
        byte[] enc0 = Rans.encode(data, 0);
        byte[] enc1 = Rans.encode(data, 1);
        assertArrayEquals(loadFixture("rans_c_o0.bin"), enc0, "vector C order-0 byte-exact");
        assertArrayEquals(loadFixture("rans_c_o1.bin"), enc1, "vector C order-1 byte-exact");
        assertArrayEquals(data, Rans.decode(enc0), "vector C order-0 round-trip");
        assertArrayEquals(data, Rans.decode(enc1), "vector C order-1 round-trip");
        assertTrue(enc1.length < enc0.length,
            "order-1 (" + enc1.length + ") should beat order-0 (" + enc0.length + ") on cyclic data");
    }

    // ── 13. Decode malformed ────────────────────────────────────────

    @Test
    void decodeMalformed() {
        byte[] payload = new byte[1100];
        for (int i = 0; i < payload.length; i++) {
            payload[i] = (byte) ("hello world".charAt(i % 11));
        }
        byte[] good = Rans.encode(payload, 0);

        // Null input.
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(null), "null input");
        // Empty.
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(new byte[0]), "empty input");
        // Shorter than header.
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(new byte[]{0, 0, 0}), "shorter than header");
        // Bad order byte.
        byte[] badOrder = good.clone();
        badOrder[0] = 0x05;
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(badOrder), "bad order byte");
        // Truncated payload.
        byte[] truncated = Arrays.copyOf(good, good.length - 4);
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(truncated), "truncated payload");
        // Truncated freq table.
        byte[] tooShort = Arrays.copyOf(good, 50);
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(tooShort), "truncated freq table");
        // Header lies about payload length — actual stream too short.
        byte[] badLen = good.clone();
        int declared = ((badLen[5] & 0xFF) << 24) | ((badLen[6] & 0xFF) << 16)
            | ((badLen[7] & 0xFF) << 8) | (badLen[8] & 0xFF);
        int bumped = declared + 16;
        badLen[5] = (byte) (bumped >>> 24);
        badLen[6] = (byte) (bumped >>> 16);
        badLen[7] = (byte) (bumped >>> 8);
        badLen[8] = (byte) bumped;
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(badLen), "header lies about payload length");

        // Order-1 with corrupted row sum.
        byte[] enc1 = Rans.encode("abcabcabc".getBytes(), 1);
        int off = 9;
        boolean fixed = false;
        for (int ctx = 0; ctx < 256; ctx++) {
            int nNz = ((enc1[off] & 0xFF) << 8) | (enc1[off + 1] & 0xFF);
            off += 2;
            if (nNz > 0) {
                int f = ((enc1[off + 1] & 0xFF) << 8) | (enc1[off + 2] & 0xFF);
                int bumpedF = f + 1;
                enc1[off + 1] = (byte) (bumpedF >>> 8);
                enc1[off + 2] = (byte) bumpedF;
                fixed = true;
                break;
            }
        }
        assertTrue(fixed, "test setup: must find a non-empty row to corrupt");
        assertThrows(IllegalArgumentException.class,
            () -> Rans.decode(enc1), "corrupted order-1 row sum");

        // Bad order on encode.
        assertThrows(IllegalArgumentException.class,
            () -> Rans.encode(new byte[]{0x78}, 2), "bad encode order");
        // Null data on encode.
        assertThrows(IllegalArgumentException.class,
            () -> Rans.encode(null, 0), "null encode data");
    }

    // ── 14. Throughput logging ──────────────────────────────────────

    @Test
    void throughput() {
        int n = 4 * (1 << 20); // 4 MiB
        byte[] data = new byte[n];
        new SecureRandom().nextBytes(data);

        long t0 = System.nanoTime();
        byte[] enc = Rans.encode(data, 0);
        long encDt = System.nanoTime() - t0;

        long t1 = System.nanoTime();
        byte[] dec = Rans.decode(enc);
        long decDt = System.nanoTime() - t1;

        double mib = (double) n / (1 << 20);
        double encMbS = mib / (encDt / 1e9);
        double decMbS = mib / (decDt / 1e9);
        System.out.printf(
            "%n  M83 throughput (4 MiB, order-0, Java): "
                + "encode %.2f MB/s, decode %.2f MB/s%n",
            encMbS, decMbS);

        assertArrayEquals(data, dec, "throughput round-trip integrity");
        // No hard threshold (JIT warm-up variability) — just verify they're > 0.
        assertTrue(encMbS > 0.0, "encode throughput > 0");
        assertTrue(decMbS > 0.0, "decode throughput > 0");
    }
}
