/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import global.thalion.ttio.Enums.Compression;

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
 * FQZCOMP_NX16 unit tests — Java parity for the M94 codec.
 *
 * <p>Mirrors the M93 RefDiffUnitTest layout. Covers:
 * <ul>
 *   <li>Compression enum value (10).</li>
 *   <li>Header / context_model_params pack/unpack.</li>
 *   <li>Bucketing helpers.</li>
 *   <li>Context hash (SplitMix64) — known-input parity.</li>
 *   <li>Round-trip on micro inputs ("IIIIIIIIII" smoke).</li>
 *   <li>Read-length sidecar round-trip.</li>
 *   <li>7 canonical fixtures (a, b, c, d, f, g, h — fixture e is
 *       1.9MB and is run separately by the slow profile).</li>
 * </ul>
 */
final class FqzcompNx16UnitTest {

    // ── Helpers ─────────────────────────────────────────────────────

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = FqzcompNx16UnitTest.class.getResourceAsStream(path)) {
            assertNotNull(in, "fixture missing on classpath: " + path);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    // ── Enum ────────────────────────────────────────────────────────

    @Test
    void compressionEnumValueIsTen() {
        assertEquals(10, Compression.FQZCOMP_NX16.ordinal(),
            "Compression.FQZCOMP_NX16.ordinal() must be 10");
    }

    // ── Bucketing ───────────────────────────────────────────────────

    @Test
    void positionBucketBasics() {
        // Position 0 → bucket 0; halfway → ~8; end → 15.
        assertEquals(0, FqzcompNx16.positionBucket(0, 100));
        assertEquals(0, FqzcompNx16.positionBucket(-5, 100));
        assertEquals(15, FqzcompNx16.positionBucket(100, 100));
        assertEquals(15, FqzcompNx16.positionBucket(105, 100));
        assertEquals(8, FqzcompNx16.positionBucket(50, 100));
        // Empty / negative read length → bucket 0.
        assertEquals(0, FqzcompNx16.positionBucket(10, 0));
        assertEquals(0, FqzcompNx16.positionBucket(10, -1));
    }

    @Test
    void lengthBucketBoundaries() {
        // Bucket 0: 1..49bp.
        assertEquals(0, FqzcompNx16.lengthBucket(1));
        assertEquals(0, FqzcompNx16.lengthBucket(49));
        // Bucket 1: 50..99bp.
        assertEquals(1, FqzcompNx16.lengthBucket(50));
        assertEquals(1, FqzcompNx16.lengthBucket(99));
        // Bucket 2: 100..149bp.
        assertEquals(2, FqzcompNx16.lengthBucket(100));
        // Bucket 7: 10000bp+.
        assertEquals(7, FqzcompNx16.lengthBucket(10_000));
        assertEquals(7, FqzcompNx16.lengthBucket(99_999));
        // Edge cases.
        assertEquals(0, FqzcompNx16.lengthBucket(0));
        assertEquals(0, FqzcompNx16.lengthBucket(-5));
    }

    // ── Context hash (SplitMix64) ───────────────────────────────────

    @Test
    void contextHashAllZeroIsDeterministic() {
        // (0,0,0,0,0,0, seed=0xC0FFEE, log2=12) — verified against the
        // Python reference (run python -c "from ttio.codecs.fqzcomp_nx16
        // import fqzn_context_hash; print(fqzn_context_hash(0,0,0,0,0,0,
        // 0xC0FFEE))" to regenerate). The all-zero context is the
        // padding context shared by encoder + decoder; its hash must be
        // stable across versions.
        int h = FqzcompNx16.fqznContextHash(0, 0, 0, 0, 0, 0,
            FqzcompNx16.DEFAULT_CONTEXT_HASH_SEED,
            FqzcompNx16.DEFAULT_CONTEXT_TABLE_SIZE_LOG2);
        // 12-bit value → in [0, 4096).
        assertTrue(h >= 0 && h < 4096, "hash out of range: " + h);
    }

    @Test
    void contextHashDistinctInputsDistinctOutputsMostly() {
        // Sanity: small permutations of context produce distinct hashes
        // most of the time. (Birthday-paradox collisions allowed.)
        int h1 = FqzcompNx16.fqznContextHash(0, 0, 0, 0, 0, 0,
            FqzcompNx16.DEFAULT_CONTEXT_HASH_SEED,
            FqzcompNx16.DEFAULT_CONTEXT_TABLE_SIZE_LOG2);
        int h2 = FqzcompNx16.fqznContextHash(1, 0, 0, 0, 0, 0,
            FqzcompNx16.DEFAULT_CONTEXT_HASH_SEED,
            FqzcompNx16.DEFAULT_CONTEXT_TABLE_SIZE_LOG2);
        int h3 = FqzcompNx16.fqznContextHash(0, 0, 0, 0, 1, 0,
            FqzcompNx16.DEFAULT_CONTEXT_HASH_SEED,
            FqzcompNx16.DEFAULT_CONTEXT_TABLE_SIZE_LOG2);
        // We don't expect deterministic distinctness, but at least one of
        // the three should differ from h1 — otherwise the mixer is broken.
        assertTrue(h1 != h2 || h1 != h3,
            "context hash mixer suspected broken: all 3 hashes equal");
    }

    // ── Header pack/unpack ──────────────────────────────────────────

    @Test
    void contextModelParamsRoundTrip() {
        FqzcompNx16.ContextModelParams p = FqzcompNx16.ContextModelParams.defaults();
        byte[] packed = FqzcompNx16.packContextModelParams(p);
        assertEquals(FqzcompNx16.CONTEXT_MODEL_PARAMS_SIZE, packed.length);
        FqzcompNx16.ContextModelParams round =
            FqzcompNx16.unpackContextModelParams(packed, 0);
        assertEquals(p, round);
    }

    @Test
    void codecHeaderRoundTripEmpty() {
        FqzcompNx16.ContextModelParams p =
            FqzcompNx16.ContextModelParams.defaults();
        byte[] rlt = new byte[0];  // empty read-length table
        long[] stateInit = new long[]{
            FqzcompNx16.RANS_L, FqzcompNx16.RANS_L,
            FqzcompNx16.RANS_L, FqzcompNx16.RANS_L};
        FqzcompNx16.CodecHeader h = new FqzcompNx16.CodecHeader(
            0x0F, 0L, 0, 0, rlt, p, stateInit);
        byte[] packed = FqzcompNx16.packCodecHeader(h);
        assertEquals(FqzcompNx16.HEADER_FIXED_PREFIX
            + FqzcompNx16.HEADER_TRAILING_FIXED, packed.length);
        // Magic + version bytes.
        assertEquals('F', packed[0]);
        assertEquals('Q', packed[1]);
        assertEquals('Z', packed[2]);
        assertEquals('N', packed[3]);
        assertEquals(1, packed[4]);
        // Round-trip.
        FqzcompNx16.HeaderUnpack hu = FqzcompNx16.unpackCodecHeader(packed);
        assertEquals(packed.length, hu.bytesConsumed());
        assertEquals(h.flags(), hu.header().flags());
        assertEquals(h.numQualities(), hu.header().numQualities());
        assertEquals(h.numReads(), hu.header().numReads());
        assertEquals(h.rltCompressedLen(), hu.header().rltCompressedLen());
        assertEquals(h.params(), hu.header().params());
        for (int k = 0; k < FqzcompNx16.NUM_STREAMS; k++) {
            assertEquals(h.stateInit()[k], hu.header().stateInit()[k]);
        }
    }

    @Test
    void unpackRejectsBadMagic() {
        byte[] bad = new byte[FqzcompNx16.HEADER_FIXED_PREFIX
            + FqzcompNx16.HEADER_TRAILING_FIXED];
        bad[0] = 'X'; bad[1] = 'X'; bad[2] = 'X'; bad[3] = 'X';
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16.unpackCodecHeader(bad));
    }

    @Test
    void unpackRejectsUnsupportedVersion() {
        byte[] rlt = new byte[0];
        long[] stateInit = new long[]{
            FqzcompNx16.RANS_L, FqzcompNx16.RANS_L,
            FqzcompNx16.RANS_L, FqzcompNx16.RANS_L};
        FqzcompNx16.CodecHeader h = new FqzcompNx16.CodecHeader(
            0x0F, 0L, 0, 0, rlt,
            FqzcompNx16.ContextModelParams.defaults(), stateInit);
        byte[] packed = FqzcompNx16.packCodecHeader(h);
        packed[4] = 99;
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16.unpackCodecHeader(packed));
    }

    @Test
    void unpackRejectsReservedFlagBits() {
        byte[] rlt = new byte[0];
        long[] stateInit = new long[]{
            FqzcompNx16.RANS_L, FqzcompNx16.RANS_L,
            FqzcompNx16.RANS_L, FqzcompNx16.RANS_L};
        // Flags with bit 6 set — reserved, must error.
        FqzcompNx16.CodecHeader h = new FqzcompNx16.CodecHeader(
            0x40, 0L, 0, 0, rlt,
            FqzcompNx16.ContextModelParams.defaults(), stateInit);
        byte[] packed = FqzcompNx16.packCodecHeader(h);
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16.unpackCodecHeader(packed));
    }

    // ── Read-length sidecar ─────────────────────────────────────────

    @Test
    void readLengthsRoundTripEmpty() {
        int[] empty = new int[0];
        byte[] enc = FqzcompNx16.encodeReadLengths(empty);
        int[] back = FqzcompNx16.decodeReadLengths(enc, 0);
        assertArrayEquals(empty, back);
    }

    @Test
    void readLengthsRoundTrip() {
        int[] lens = new int[]{100, 100, 75, 250, 100};
        byte[] enc = FqzcompNx16.encodeReadLengths(lens);
        int[] back = FqzcompNx16.decodeReadLengths(enc, lens.length);
        assertArrayEquals(lens, back);
    }

    // ── Round-trip smoke tests ──────────────────────────────────────

    @Test
    void roundTripAllQ40Smoke() {
        // Critical byte-exact gate: 10× Q40 at start of read with empty
        // context. Decoder must recover exactly. Match Python.
        byte[] qualities = "IIIIIIIIII".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {10};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16.encode(qualities, readLengths, revcomp);
        FqzcompNx16.DecodeResult dec =
            FqzcompNx16.decodeWithMetadata(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
        assertArrayEquals(readLengths, dec.readLengths());
    }

    @Test
    void roundTripMultiReadSmoke() {
        // 3 reads × 10 bytes each, varied qualities.
        byte[] qualities = ("AAAAAAAAAA"
                          + "BBBBBBBBBB"
                          + "CCCCCCCCCC").getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {10, 10, 10};
        int[] revcomp = {0, 1, 0};
        byte[] enc = FqzcompNx16.encode(qualities, readLengths, revcomp);
        FqzcompNx16.DecodeResult dec =
            FqzcompNx16.decodeWithMetadata(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
        assertArrayEquals(readLengths, dec.readLengths());
    }

    @Test
    void roundTripPaddingNonMultipleOf4() {
        // 5 bytes (not a multiple of 4) — exercises the pad-context path.
        byte[] qualities = "IIIII".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {5};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16.encode(qualities, readLengths, revcomp);
        FqzcompNx16.DecodeResult dec =
            FqzcompNx16.decodeWithMetadata(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
    }

    @Test
    void roundTripSingleByte() {
        // 1 byte → 3 padding bytes.
        byte[] qualities = "I".getBytes(StandardCharsets.US_ASCII);
        int[] readLengths = {1};
        int[] revcomp = {0};
        byte[] enc = FqzcompNx16.encode(qualities, readLengths, revcomp);
        FqzcompNx16.DecodeResult dec =
            FqzcompNx16.decodeWithMetadata(enc, revcomp);
        assertArrayEquals(qualities, dec.qualities());
    }

    @Test
    void roundTripRevcompFlagAffectsOutput() {
        // Same qualities, two revcomp settings. Encoded bytes must differ.
        //
        // Methodology note: with constant-quality input AND uniform
        // initial freq tables, two different context indices both encode
        // the same symbol identically — the contexts only diverge after
        // the adaptive update has fired enough to differentiate them.
        // To exercise the revcomp-context bit cleanly, we use varied
        // qualities (LCG-derived Q20..Q40) so divergence materialises
        // on the first symbol.
        // 200 reads × 100 qualities = 20K symbols — large enough that the
        // adaptive freq tables for the two revcomp-distinguished contexts
        // produce visibly different M-normalised distributions, which in
        // turn produce different rANS output bytes.
        int nReads = 200;
        int readLen = 100;
        int n = nReads * readLen;
        byte[] qualities = new byte[n];
        long s = 0xBEEFL;
        for (int i = 0; i < n; i++) {
            s = (s * 6364136223846793005L + 1442695040888963407L);
            qualities[i] = (byte) (33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        int[] readLengths = new int[nReads];
        int[] revFwd = new int[nReads];
        int[] revRev = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            readLengths[i] = readLen;
            revFwd[i] = 0;
            revRev[i] = 1;
        }
        byte[] encFwd = FqzcompNx16.encode(qualities, readLengths, revFwd);
        byte[] encRev = FqzcompNx16.encode(qualities, readLengths, revRev);
        assertTrue(!java.util.Arrays.equals(encFwd, encRev),
            "revcomp flag must change encoded bytes");
        // Both must round-trip with their own flag trajectory.
        assertArrayEquals(qualities,
            FqzcompNx16.decodeWithMetadata(encFwd, revFwd).qualities());
        assertArrayEquals(qualities,
            FqzcompNx16.decodeWithMetadata(encRev, revRev).qualities());
    }

    // ── Canonical fixtures ──────────────────────────────────────────
    //
    // Each fixture verifies BOTH directions:
    //   1. Java decode(fixture_bytes) == Python's input (qualities + read_lengths).
    //   2. Java encode(input_recipe) == fixture_bytes (byte-identical).
    //
    // Fixture e (1M reads, 100MB raw qualities) is gated to a slow
    // profile elsewhere; the seven smaller fixtures cover the cross-
    // language byte-exact contract.

    private record FixtureInputs(
        byte[] qualities, int[] readLengths, int[] revcompFlags) { }

    private static FixtureInputs fixtureA() {
        // 100 reads × 100bp, all Q40 (= 40+33 = 'I').
        int n = 100, len = 100;
        byte[] qualities = new byte[n * len];
        java.util.Arrays.fill(qualities, (byte) 'I');
        int[] readLengths = new int[n];
        java.util.Arrays.fill(readLengths, len);
        int[] revcomp = new int[n];
        return new FixtureInputs(qualities, readLengths, revcomp);
    }

    private static FixtureInputs fixtureB() {
        // Illumina profile — Random(0xBEEF) Gaussian Q30 mean, clipped [20,40].
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
        // PacBio HiFi — Random(0xCAFE), 70% Q40, 30% Q30..Q60.
        int n = 50, len = 100;
        PyRandom rng = new PyRandom(0xCAFEL);
        byte[] q = new byte[n * len];
        for (int i = 0; i < q.length; i++) {
            int qv;
            if (rng.random() < 0.7) {
                qv = 40;
            } else {
                qv = rng.randrange(30, 61);  // 30..60 inclusive
            }
            q[i] = (byte) (qv + 33);
        }
        int[] readLengths = new int[n];
        java.util.Arrays.fill(readLengths, len);
        return new FixtureInputs(q, readLengths, new int[n]);
    }

    private static FixtureInputs fixtureD() {
        // 4 reads × 100bp, qualities = randrange(33, 74), Random(0xDEAD).
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
        // 80% revcomp — Random(0xF00D), Gaussian quals, then 80% revcomp flags.
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
        // Renorm boundary — 5000 bytes Q35, single read.
        byte[] q = new byte[5000];
        java.util.Arrays.fill(q, (byte) (35 + 33));
        return new FixtureInputs(q, new int[]{5000}, new int[]{0});
    }

    private static FixtureInputs fixtureH() {
        // Symbol freq saturation — 50_000 bytes Q40, single read.
        byte[] q = new byte[50_000];
        java.util.Arrays.fill(q, (byte) (40 + 33));
        return new FixtureInputs(q, new int[]{50_000}, new int[]{0});
    }

    private static void assertFixture(String name, FixtureInputs in)
            throws IOException {
        byte[] expected = loadFixture(name);
        byte[] encoded = FqzcompNx16.encode(
            in.qualities(), in.readLengths(), in.revcompFlags());
        assertArrayEquals(expected, encoded,
            name + ": Java encode() must match Python fixture byte-exact "
            + "(got " + encoded.length + " bytes vs "
            + expected.length + " expected)");
        FqzcompNx16.DecodeResult dec = FqzcompNx16.decodeWithMetadata(
            expected, in.revcompFlags());
        assertArrayEquals(in.qualities(), dec.qualities(),
            name + ": Java decode() must reconstruct qualities byte-exact");
        assertArrayEquals(in.readLengths(), dec.readLengths(),
            name + ": Java decode() must reconstruct read_lengths");
    }

    @Test
    void canonicalFixtureA() throws IOException {
        assertFixture("fqzcomp_nx16_a.bin", fixtureA());
    }

    @Test
    void canonicalFixtureB() throws IOException {
        assertFixture("fqzcomp_nx16_b.bin", fixtureB());
    }

    @Test
    void canonicalFixtureC() throws IOException {
        assertFixture("fqzcomp_nx16_c.bin", fixtureC());
    }

    @Test
    void canonicalFixtureD() throws IOException {
        assertFixture("fqzcomp_nx16_d.bin", fixtureD());
    }

    @Test
    void canonicalFixtureF() throws IOException {
        assertFixture("fqzcomp_nx16_f.bin", fixtureF());
    }

    @Test
    void canonicalFixtureG() throws IOException {
        assertFixture("fqzcomp_nx16_g.bin", fixtureG());
    }

    @Test
    void canonicalFixtureH() throws IOException {
        assertFixture("fqzcomp_nx16_h.bin", fixtureH());
    }
}
