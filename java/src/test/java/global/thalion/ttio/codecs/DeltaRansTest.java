/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import global.thalion.ttio.Enums;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

import static org.junit.jupiter.api.Assertions.*;

final class DeltaRansTest {

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = DeltaRansTest.class.getResourceAsStream(path)) {
            assertNotNull(in, "fixture missing: " + path);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    @Test void enumOrdinals() {
        assertEquals(11, Enums.Compression.DELTA_RANS_ORDER0.ordinal());
        assertEquals(12, Enums.Compression.FQZCOMP_NX16_Z.ordinal());
    }

    @Test void roundTripInt64SortedAscending() {
        ByteBuffer bb = ByteBuffer.allocate(100 * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < 100; i++) bb.putLong(1000L + i * 150L);
        byte[] raw = bb.array();
        byte[] encoded = DeltaRans.encode(raw, 8);
        assertEquals((byte) 'D', encoded[0]);
        assertEquals((byte) 'R', encoded[1]);
        assertEquals((byte) 'A', encoded[2]);
        assertEquals((byte) '0', encoded[3]);
        assertArrayEquals(raw, DeltaRans.decode(encoded));
    }

    @Test void roundTripInt32Bimodal() {
        int[] vals = {350, -350, 351, -349, 348, -352};
        ByteBuffer bb = ByteBuffer.allocate(120 * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int r = 0; r < 20; r++)
            for (int v : vals) bb.putInt(v);
        byte[] raw = bb.array();
        assertArrayEquals(raw, DeltaRans.decode(DeltaRans.encode(raw, 4)));
    }

    @Test void roundTripInt8() {
        byte[] raw = {10, 20, 30, 40, 50, 60};
        assertArrayEquals(raw, DeltaRans.decode(DeltaRans.encode(raw, 1)));
    }

    @Test void roundTripEmpty() {
        byte[] encoded = DeltaRans.encode(new byte[0], 8);
        assertEquals((byte) 'D', encoded[0]);
        assertArrayEquals(new byte[0], DeltaRans.decode(encoded));
    }

    @Test void roundTripSingleElement() {
        ByteBuffer bb = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        bb.putLong(42L);
        byte[] raw = bb.array();
        assertArrayEquals(raw, DeltaRans.decode(DeltaRans.encode(raw, 8)));
    }

    @Test void roundTripNegativeDeltas() {
        ByteBuffer bb = ByteBuffer.allocate(5 * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (long v : new long[]{1000, 900, 800, 700, 600}) bb.putLong(v);
        byte[] raw = bb.array();
        assertArrayEquals(raw, DeltaRans.decode(DeltaRans.encode(raw, 8)));
    }

    @Test void headerFields() {
        ByteBuffer bb = ByteBuffer.allocate(4 * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (long v : new long[]{100, 200, 300, 400}) bb.putLong(v);
        byte[] encoded = DeltaRans.encode(bb.array(), 8);
        assertEquals((byte) 'D', encoded[0]);
        assertEquals((byte) 'R', encoded[1]);
        assertEquals((byte) 'A', encoded[2]);
        assertEquals((byte) '0', encoded[3]);
        assertEquals(1, encoded[4] & 0xFF);  // version
        assertEquals(8, encoded[5] & 0xFF);  // element_size
        assertEquals(0, encoded[6]);         // reserved
        assertEquals(0, encoded[7]);         // reserved
    }

    @Test void badMagicRejected() {
        byte[] encoded = DeltaRans.encode(
            ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(42).array(), 8);
        encoded[0] = 'X';
        assertThrows(IllegalArgumentException.class, () -> DeltaRans.decode(encoded));
    }

    @Test void badVersionRejected() {
        byte[] encoded = DeltaRans.encode(
            ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(42).array(), 8);
        encoded[4] = 99;
        assertThrows(IllegalArgumentException.class, () -> DeltaRans.decode(encoded));
    }

    @Test void invalidElementSizeEncodeRejected() {
        assertThrows(IllegalArgumentException.class,
            () -> DeltaRans.encode(new byte[3], 3));
    }

    @Test void invalidElementSizeDecodeRejected() {
        byte[] encoded = DeltaRans.encode(
            ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(42).array(), 8);
        encoded[5] = 3;
        assertThrows(IllegalArgumentException.class, () -> DeltaRans.decode(encoded));
    }

    // ── Fixture parity ──────────────────────────────────────────────

    @Test void fixtureASortedInt64() throws IOException {
        byte[] encoded = loadFixture("delta_rans_a.bin");
        byte[] decoded = DeltaRans.decode(encoded);
        assertEquals(1000 * 8, decoded.length);
        ByteBuffer bb = ByteBuffer.wrap(decoded).order(ByteOrder.LITTLE_ENDIAN);
        long prev = Long.MIN_VALUE;
        for (int i = 0; i < 1000; i++) {
            long v = bb.getLong();
            assertTrue(v > prev, "sorted ascending at index " + i);
            prev = v;
        }
    }

    @Test void fixtureBUint32Flags() throws IOException {
        byte[] encoded = loadFixture("delta_rans_b.bin");
        byte[] decoded = DeltaRans.decode(encoded);
        assertEquals(100 * 4, decoded.length);
        ByteBuffer bb = ByteBuffer.wrap(decoded).order(ByteOrder.LITTLE_ENDIAN);
        java.util.Set<Integer> seen = new java.util.HashSet<>();
        for (int i = 0; i < 100; i++) seen.add(bb.getInt());
        assertEquals(java.util.Set.of(0, 16, 83, 99, 163), seen);
    }

    @Test void fixtureCEmpty() throws IOException {
        byte[] encoded = loadFixture("delta_rans_c.bin");
        byte[] decoded = DeltaRans.decode(encoded);
        assertEquals(0, decoded.length);
    }

    @Test void fixtureDSingle() throws IOException {
        byte[] encoded = loadFixture("delta_rans_d.bin");
        byte[] decoded = DeltaRans.decode(encoded);
        assertEquals(8, decoded.length);
        long v = ByteBuffer.wrap(decoded).order(ByteOrder.LITTLE_ENDIAN).getLong();
        assertEquals(1234567890L, v);
    }

    @Test void fixtureAReEncodeExact() throws IOException {
        byte[] encoded = loadFixture("delta_rans_a.bin");
        byte[] decoded = DeltaRans.decode(encoded);
        byte[] reEncoded = DeltaRans.encode(decoded, 8);
        assertArrayEquals(encoded, reEncoded, "re-encode must be byte-exact");
    }

    @Test void fixtureBReEncodeExact() throws IOException {
        byte[] encoded = loadFixture("delta_rans_b.bin");
        byte[] decoded = DeltaRans.decode(encoded);
        byte[] reEncoded = DeltaRans.encode(decoded, 4);
        assertArrayEquals(encoded, reEncoded, "re-encode must be byte-exact");
    }

    @Test void roundTripInt8WrappingDeltas() {
        byte[] raw = {127, -128, 0, -1, 1};
        byte[] encoded = DeltaRans.encode(raw, 1);
        assertArrayEquals(raw, DeltaRans.decode(encoded));
    }

    @Test void roundTripInt32WrappingDeltas() {
        ByteBuffer bb = ByteBuffer.allocate(3 * 4).order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(Integer.MAX_VALUE);
        bb.putInt(Integer.MIN_VALUE);
        bb.putInt(0);
        byte[] raw = bb.array();
        assertArrayEquals(raw, DeltaRans.decode(DeltaRans.encode(raw, 4)));
    }
}
