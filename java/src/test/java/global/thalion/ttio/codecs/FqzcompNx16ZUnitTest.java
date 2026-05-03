/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * FQZCOMP_NX16.Z unit tests — Java parity for the M94.Z (CRAM-mimic) codec.
 *
 * <p>Mirrors {@code FqzcompNx16UnitTest} but for the M94.Z codec. The
 * 7 canonical fixtures (a..d, f..h) are byte-exact across Python /
 * Cython / Java.
 */
final class FqzcompNx16ZUnitTest {

    // ── Helpers ─────────────────────────────────────────────────────

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = FqzcompNx16ZUnitTest.class.getResourceAsStream(path)) {
            assertNotNull(in, "fixture missing on classpath: " + path);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    // ── Constants and helpers ──────────────────────────────────────

    @Test
    void constantsMatchSpec() {
        assertEquals(32_768, FqzcompNx16Z.L);
        assertEquals(16, FqzcompNx16Z.B_BITS);
        assertEquals(65_536, FqzcompNx16Z.B);
        assertEquals(0xFFFF, FqzcompNx16Z.B_MASK);
        assertEquals(4096, FqzcompNx16Z.T);
        assertEquals(12, FqzcompNx16Z.T_BITS);
        assertEquals(4, FqzcompNx16Z.NUM_STREAMS);
        // X_MAX_PREFACTOR = 2^19.
        assertEquals(1 << 19, FqzcompNx16Z.X_MAX_PREFACTOR);
    }

    @Test
    void magicIsM94Z() {
        assertEquals('M', FqzcompNx16Z.MAGIC[0]);
        assertEquals('9', FqzcompNx16Z.MAGIC[1]);
        assertEquals('4', FqzcompNx16Z.MAGIC[2]);
        assertEquals('Z', FqzcompNx16Z.MAGIC[3]);
        assertEquals(1, FqzcompNx16Z.VERSION);
    }

    @Test
    void positionBucketPbitsBasics() {
        // Pos 0 → bucket 0.
        assertEquals(0, FqzcompNx16Z.positionBucketPbits(0, 100, 2));
        // Pos at end → bucket 3 (= 2^pbits - 1).
        assertEquals(3, FqzcompNx16Z.positionBucketPbits(100, 100, 2));
        assertEquals(3, FqzcompNx16Z.positionBucketPbits(105, 100, 2));
        // Mid → 2.
        assertEquals(2, FqzcompNx16Z.positionBucketPbits(50, 100, 2));
        // pbits=0 always → 0.
        assertEquals(0, FqzcompNx16Z.positionBucketPbits(50, 100, 0));
        // Empty / negative.
        assertEquals(0, FqzcompNx16Z.positionBucketPbits(10, 0, 2));
        assertEquals(0, FqzcompNx16Z.positionBucketPbits(-1, 100, 2));
    }

    @Test
    void contextBitPackBasics() {
        // qbits=12, pbits=2, sloc=14; revcomp=1, prevQ=0xABC, posBucket=2
        // → ctx = 0xABC | (2 << 12) | (1 << 14) = 0xABC | 0x2000 | 0x4000
        // Then & 0x3FFF (mask to 14 bits) → 0xABC | 0x2000 = 0x2ABC.
        int ctx = FqzcompNx16Z.m94zContext(0xABC, 2, 1, 12, 2, 14);
        // 0xABC | (2 << 12) | (1 << 14) = 0xABC | 0x2000 | 0x4000 = 0x6ABC,
        // masked to 14 bits = 0x2ABC.
        assertEquals(0x2ABC, ctx);
    }

    // ── ContextParams pack/unpack ───────────────────────────────────

    @Test
    void contextParamsRoundTrip() {
        FqzcompNx16Z.ContextParams p = FqzcompNx16Z.ContextParams.defaults();
        byte[] packed = FqzcompNx16Z.packContextParams(p);
        assertEquals(FqzcompNx16Z.CONTEXT_PARAMS_SIZE, packed.length);
        FqzcompNx16Z.ContextParams round = FqzcompNx16Z.unpackContextParams(packed, 0);
        assertEquals(p, round);
    }

    // ── Read-length sidecar ─────────────────────────────────────────

    @Test
    void readLengthsRoundTripEmpty() {
        int[] empty = new int[0];
        byte[] enc = FqzcompNx16Z.encodeReadLengths(empty);
        int[] back = FqzcompNx16Z.decodeReadLengths(enc, 0);
        assertArrayEquals(empty, back);
    }

    @Test
    void readLengthsRoundTrip() {
        int[] lens = {100, 100, 75, 250, 100};
        byte[] enc = FqzcompNx16Z.encodeReadLengths(lens);
        int[] back = FqzcompNx16Z.decodeReadLengths(enc, lens.length);
        assertArrayEquals(lens, back);
    }

    // ── Round-trip smoke tests ──────────────────────────────────────

    @Test
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
    void roundTripSingleByte() {
        byte[] qualities = "I".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {1};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16Z.encode(qualities, readLengths, revcomp);
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
    }

    @Test
    void roundTripPaddingNonMultipleOf4() {
        byte[] qualities = "IIIII".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {5};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16Z.encode(qualities, readLengths, revcomp);
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
    }

    @Test
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

    // ── Canonical fixtures (the byte-exact contract) ────────────────

    private record FixtureInputs(
        byte[] qualities, int[] readLengths, int[] revcompFlags) { }

    private static FixtureInputs fixtureA() {
        // 100 reads × 100bp, all Q40.
        int n = 100, len = 100;
        byte[] qualities = new byte[n * len];
        java.util.Arrays.fill(qualities, (byte) (40 + 33));
        int[] readLengths = new int[n];
        java.util.Arrays.fill(readLengths, len);
        int[] revcomp = new int[n];
        return new FixtureInputs(qualities, readLengths, revcomp);
    }

    private static FixtureInputs fixtureB() {
        // Illumina profile — Random(0xBEEF).
        int n = 100, len = 100;
        PyRandom rng = new PyRandom(0xBEEFL);
        byte[] q = new byte[n * len];
        for (int i = 0; i < q.length; i++) {
            int qv = (int) Math.max(20, Math.min(40, rng.gauss(30, 5)));
            q[i] = (byte) (qv + 33);
        }
        int[] readLengths = new int[n];
        java.util.Arrays.fill(readLengths, len);
        return new FixtureInputs(q, readLengths, new int[n]);
    }

    private static FixtureInputs fixtureC() {
        // PacBio HiFi — Random(0xCAFE).
        int n = 50, len = 100;
        PyRandom rng = new PyRandom(0xCAFEL);
        byte[] q = new byte[n * len];
        for (int i = 0; i < q.length; i++) {
            int qv;
            if (rng.random() < 0.7) {
                qv = 40;
            } else {
                qv = rng.randrange(30, 61);
            }
            q[i] = (byte) (qv + 33);
        }
        int[] readLengths = new int[n];
        java.util.Arrays.fill(readLengths, len);
        return new FixtureInputs(q, readLengths, new int[n]);
    }

    private static FixtureInputs fixtureD() {
        PyRandom rng = new PyRandom(0xDEADL);
        byte[] q = new byte[4 * 100];
        for (int i = 0; i < q.length; i++) {
            q[i] = (byte) rng.randrange(33, 74);
        }
        int[] readLengths = {100, 100, 100, 100};
        int[] revcomp = {0, 1, 0, 1};
        return new FixtureInputs(q, readLengths, revcomp);
    }

    private static FixtureInputs fixtureF() {
        int n = 100, len = 100;
        PyRandom rng = new PyRandom(0xF00DL);
        byte[] q = new byte[n * len];
        for (int i = 0; i < q.length; i++) {
            int qv = (int) Math.max(20, Math.min(40, rng.gauss(30, 5)));
            q[i] = (byte) (qv + 33);
        }
        int[] revcomp = new int[n];
        for (int i = 0; i < n; i++) revcomp[i] = (rng.random() < 0.8) ? 1 : 0;
        int[] readLengths = new int[n];
        java.util.Arrays.fill(readLengths, len);
        return new FixtureInputs(q, readLengths, revcomp);
    }

    private static FixtureInputs fixtureG() {
        byte[] q = new byte[5000];
        java.util.Arrays.fill(q, (byte) (35 + 33));
        return new FixtureInputs(q, new int[]{5000}, new int[]{0});
    }

    private static FixtureInputs fixtureH() {
        byte[] q = new byte[50_000];
        java.util.Arrays.fill(q, (byte) (40 + 33));
        return new FixtureInputs(q, new int[]{50_000}, new int[]{0});
    }

    private static void assertFixture(String name, FixtureInputs in)
            throws IOException {
        byte[] expected = loadFixture(name);
        // Canonical fixtures are V1 byte-equality; explicitly suppress the
        // V4 (CRAM 3.1 fqzcomp) and V2 (libttio_rans body) dispatch paths
        // so the encoder follows the pure-Java V1 codec.
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions()
            .preferV4(false).preferNative(false);
        byte[] encoded = FqzcompNx16Z.encode(
            in.qualities(), in.readLengths(), in.revcompFlags(), opts);
        assertArrayEquals(expected, encoded,
            name + ": Java encode() must match Python fixture byte-exact "
            + "(got " + encoded.length + " bytes vs "
            + expected.length + " expected)");
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(
            expected, in.revcompFlags());
        assertArrayEquals(in.qualities(), dec.qualities(),
            name + ": Java decode() must reconstruct qualities byte-exact");
        assertArrayEquals(in.readLengths(), dec.readLengths(),
            name + ": Java decode() must reconstruct read_lengths");
    }

    @Test
    void canonicalFixtureA() throws IOException {
        assertFixture("m94z_a.bin", fixtureA());
    }

    @Test
    void canonicalFixtureB() throws IOException {
        assertFixture("m94z_b.bin", fixtureB());
    }

    @Test
    void canonicalFixtureC() throws IOException {
        assertFixture("m94z_c.bin", fixtureC());
    }

    @Test
    void canonicalFixtureD() throws IOException {
        assertFixture("m94z_d.bin", fixtureD());
    }

    @Test
    void canonicalFixtureF() throws IOException {
        assertFixture("m94z_f.bin", fixtureF());
    }

    @Test
    void canonicalFixtureG() throws IOException {
        assertFixture("m94z_g.bin", fixtureG());
    }

    @Test
    void canonicalFixtureH() throws IOException {
        assertFixture("m94z_h.bin", fixtureH());
    }
}
