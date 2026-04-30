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
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * REF_DIFF unit tests — Java parity for the M93 codec.
 *
 * <p>Covers Tasks 20–23 of M93 Phase 3:
 * <ul>
 *   <li>Header / slice-index pack/unpack (Task 20).</li>
 *   <li>CIGAR walker + reverse walker (Task 21).</li>
 *   <li>Bit-pack / bit-unpack + slice encode/decode (Task 22).</li>
 *   <li>Top-level encode/decode + the 4 canonical fixtures (Task 23).</li>
 * </ul>
 *
 * <p>The fixtures under {@code src/test/resources/ttio/codecs/ref_diff_*.bin}
 * are byte-identical copies of the Python reference fixtures; Java's
 * encode/decode must round-trip them byte-exact.
 */
final class RefDiffUnitTest {

    // ── Helpers ─────────────────────────────────────────────────────

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = RefDiffUnitTest.class.getResourceAsStream(path)) {
            assertNotNull(in, "fixture missing on classpath: " + path);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    private static byte[] hex(String hex) {
        if ((hex.length() & 1) != 0) {
            throw new IllegalArgumentException("odd-length hex: " + hex);
        }
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    private static byte[] repeat(String unit, int times) {
        byte[] u = unit.getBytes(StandardCharsets.US_ASCII);
        byte[] out = new byte[u.length * times];
        for (int i = 0; i < times; i++) {
            System.arraycopy(u, 0, out, i * u.length, u.length);
        }
        return out;
    }

    private static byte[] md5(byte[] data) {
        try {
            return MessageDigest.getInstance("MD5").digest(data);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // ── Task 20: enum value + header tests ──────────────────────────

    @Test
    void compressionEnumValueIsNine() {
        assertEquals(9, Compression.REF_DIFF.ordinal(),
            "Compression.REF_DIFF.ordinal() must be 9");
    }

    @Test
    void headerRoundTripWithUri() {
        // Mirrors the Python unit test: numSlices=3, totalReads=12345,
        // md5=hex"a718...", uri="GRCh37.hs37d5". Result is 38 + 14 bytes.
        String uri = "GRCh37.hs37d5";
        byte[] md5 = hex("a718a4e4dba9d8d9e3f3b2a1c1d2e3f4");
        RefDiff.CodecHeader h = new RefDiff.CodecHeader(3, 12345L, md5, uri);
        byte[] packed = RefDiff.packCodecHeader(h);
        assertEquals(RefDiff.HEADER_FIXED_SIZE
                + uri.getBytes(StandardCharsets.UTF_8).length,
            packed.length);
        // Magic and version bytes.
        assertEquals('R', packed[0]);
        assertEquals('D', packed[1]);
        assertEquals('I', packed[2]);
        assertEquals('F', packed[3]);
        assertEquals(1, packed[4]);
        // Round-trip.
        RefDiff.HeaderUnpack hu = RefDiff.unpackCodecHeader(packed);
        assertEquals(packed.length, hu.bytesConsumed());
        assertEquals(3, hu.header().numSlices());
        assertEquals(12345L, hu.header().totalReads());
        assertArrayEquals(md5, hu.header().referenceMd5());
        assertEquals(uri, hu.header().referenceUri());
    }

    @Test
    void sliceIndexEntryRoundTrip() {
        RefDiff.SliceIndexEntry e = new RefDiff.SliceIndexEntry(
            1024L, 512, 100L, 200L, 7);
        byte[] packed = RefDiff.packSliceIndexEntry(e);
        assertEquals(RefDiff.SLICE_INDEX_ENTRY_SIZE, packed.length);
        RefDiff.SliceIndexEntry round = RefDiff.unpackSliceIndexEntry(packed);
        assertEquals(e, round);
    }

    @Test
    void unpackRejectsBadMagic() {
        byte[] bad = new byte[RefDiff.HEADER_FIXED_SIZE];
        bad[0] = 'X'; bad[1] = 'X'; bad[2] = 'X'; bad[3] = 'X';
        assertThrows(IllegalArgumentException.class,
            () -> RefDiff.unpackCodecHeader(bad));
    }

    @Test
    void unpackRejectsUnsupportedVersion() {
        byte[] md5 = hex("a718a4e4dba9d8d9e3f3b2a1c1d2e3f4");
        RefDiff.CodecHeader h = new RefDiff.CodecHeader(0, 0L, md5, "uri");
        byte[] packed = RefDiff.packCodecHeader(h);
        packed[4] = 99;  // bogus version
        assertThrows(IllegalArgumentException.class,
            () -> RefDiff.unpackCodecHeader(packed));
    }

    @Test
    void headerRejectsBadMd5Length() {
        byte[] tooShort = new byte[8];
        assertThrows(IllegalArgumentException.class,
            () -> new RefDiff.CodecHeader(1, 1L, tooShort, "uri"));
        byte[] tooLong = new byte[20];
        assertThrows(IllegalArgumentException.class,
            () -> new RefDiff.CodecHeader(1, 1L, tooLong, "uri"));
    }

    // ── Task 21: CIGAR walker tests ─────────────────────────────────

    @Test
    void walkAllMatch() {
        byte[] ref = repeat("ACGT", 25);  // 100 bases
        byte[] read = repeat("ACGT", 25);
        RefDiff.ReadWalkResult w = RefDiff.walkReadAgainstReference(
            read, "100M", 1L, ref);
        assertEquals(100, w.mOpFlagBits().length);
        for (int i = 0; i < 100; i++) assertEquals(0, w.mOpFlagBits()[i]);
        assertEquals(0, w.substitutionBases().length);
        assertEquals(0, w.insertionBases().length);
        assertEquals(0, w.softclipBases().length);
        assertArrayEquals(read,
            RefDiff.reconstructReadFromWalk(w, "100M", 1L, ref));
    }

    @Test
    void walkSubstitutionAtIndex2() {
        byte[] ref = "ACGTA".getBytes(StandardCharsets.US_ASCII);
        byte[] read = "ACCTA".getBytes(StandardCharsets.US_ASCII);  // sub @ 2
        RefDiff.ReadWalkResult w = RefDiff.walkReadAgainstReference(
            read, "5M", 1L, ref);
        assertArrayEquals(new int[]{0, 0, 1, 0, 0}, w.mOpFlagBits());
        assertArrayEquals(new byte[]{'C'}, w.substitutionBases());
        assertArrayEquals(read,
            RefDiff.reconstructReadFromWalk(w, "5M", 1L, ref));
    }

    @Test
    void walkInsertionAndSoftclip() {
        byte[] ref = "ACGTAC".getBytes(StandardCharsets.US_ASCII);
        // 2S2M2I2M: NN | AC | NN | TA — read length 8, ref consumes 4 bases
        byte[] read = "NNACNNTA".getBytes(StandardCharsets.US_ASCII);
        // ref[0..3] = "ACGT" — wait, 2M2I2M consumes 2+0+2 = 4 ref bases.
        // To get all-match on the M ops, read[2..3]="AC" must match ref[0..1]="AC"
        // and read[6..7]="TA" must match ref[2..3]="GT" — they don't, so subs.
        RefDiff.ReadWalkResult w = RefDiff.walkReadAgainstReference(
            read, "2S2M2I2M", 1L, ref);
        // M-op flag bits = 4 (2 from first 2M + 2 from second 2M).
        assertEquals(4, w.mOpFlagBits().length);
        // First 2M: read "AC" vs ref "AC" — both match.
        assertEquals(0, w.mOpFlagBits()[0]);
        assertEquals(0, w.mOpFlagBits()[1]);
        // Second 2M: read "TA" vs ref "GT" — both substitutions.
        assertEquals(1, w.mOpFlagBits()[2]);
        assertEquals(1, w.mOpFlagBits()[3]);
        assertArrayEquals(new byte[]{'T', 'A'}, w.substitutionBases());
        assertArrayEquals(new byte[]{'N', 'N'}, w.insertionBases());
        assertArrayEquals(new byte[]{'N', 'N'}, w.softclipBases());
        assertArrayEquals(read,
            RefDiff.reconstructReadFromWalk(w, "2S2M2I2M", 1L, ref));
    }

    @Test
    void walkDeletion() {
        // 3M2D3M consumes 3+2+3 = 8 ref bases. Lay out ref so the M-op
        // spans match the read end-to-end:
        //   ref[0..2]="AAA", ref[3..4]="TT" (skipped by 2D), ref[5..7]="AAA".
        byte[] ref = "AAATTAAA".getBytes(StandardCharsets.US_ASCII);
        byte[] read = "AAAAAA".getBytes(StandardCharsets.US_ASCII);
        RefDiff.ReadWalkResult w = RefDiff.walkReadAgainstReference(
            read, "3M2D3M", 1L, ref);
        // 6 M-op bases total, all matching.
        assertEquals(6, w.mOpFlagBits().length);
        for (int b : w.mOpFlagBits()) assertEquals(0, b);
        assertEquals(0, w.substitutionBases().length);
        assertArrayEquals(read,
            RefDiff.reconstructReadFromWalk(w, "3M2D3M", 1L, ref));
    }

    @Test
    void walkHardClip() {
        byte[] ref = "ACGTA".getBytes(StandardCharsets.US_ASCII);
        // 2H3M: hard-clip carries no payload; M consumes 3 read bases + 3 ref bases.
        byte[] read = "ACG".getBytes(StandardCharsets.US_ASCII);
        RefDiff.ReadWalkResult w = RefDiff.walkReadAgainstReference(
            read, "2H3M", 1L, ref);
        assertEquals(3, w.mOpFlagBits().length);
        for (int b : w.mOpFlagBits()) assertEquals(0, b);
        assertArrayEquals(read,
            RefDiff.reconstructReadFromWalk(w, "2H3M", 1L, ref));
    }

    @Test
    void walkRejectsUnmappedCigar() {
        byte[] ref = "ACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] read = "ACGT".getBytes(StandardCharsets.US_ASCII);
        assertThrows(IllegalArgumentException.class,
            () -> RefDiff.walkReadAgainstReference(read, "*", 1L, ref));
        assertThrows(IllegalArgumentException.class,
            () -> RefDiff.walkReadAgainstReference(read, "", 1L, ref));
    }

    // ── Task 22: bit-pack / slice ───────────────────────────────────

    @Test
    void packOneSubstitution() {
        // From the Python reference: flags=[0,0,1,0,0] + sub byte 'C' (0x43).
        // Expected output: 0x28 0x60.
        // Layout walk:
        //   bit 0..1: 0 0  → flags 1, 2
        //   bit 2:    1    → flag 3 (substitution flag)
        //   bit 3..10: 0100 0011 (0x43)  → substitution byte
        //   bit 11:   0    → flag 4
        //   bit 12:   0    → flag 5
        //   pad to 16 bits with 0s.
        // Concat: 0010 1000 0110 0000 = 0x28 0x60.
        RefDiff.ReadWalkResult w = new RefDiff.ReadWalkResult(
            new int[]{0, 0, 1, 0, 0},
            new byte[]{'C'},  // 0x43
            new byte[0], new byte[0]);
        byte[] packed = RefDiff.packReadDiffBitstream(w);
        assertArrayEquals(new byte[]{0x28, 0x60}, packed,
            "bit-pack of [0,0,1,0,0] + 'C' must be 0x28 0x60");

        // And reverse: unpack must reconstruct the original walk record.
        RefDiff.ReadWalkResult round = RefDiff.unpackReadDiffBitstream(
            packed, 5, 0, 0);
        assertArrayEquals(w.mOpFlagBits(), round.mOpFlagBits());
        assertArrayEquals(w.substitutionBases(), round.substitutionBases());
        assertArrayEquals(w.insertionBases(), round.insertionBases());
        assertArrayEquals(w.softclipBases(), round.softclipBases());
    }

    @Test
    void encodeSliceRoundTrip() {
        byte[] ref = repeat("ACGT", 250);
        List<byte[]> seqs = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            seqs.add(repeat("ACGTACGTAC", 10));  // 100bp matching ref[0..99]
        }
        List<String> cigars = List.of("100M", "100M", "100M", "100M", "100M");
        long[] positions = {1, 1, 1, 1, 1};
        byte[] body = RefDiff.encodeSlice(seqs, cigars, positions, ref);
        List<byte[]> back = RefDiff.decodeSlice(body, cigars, positions, ref, 5);
        assertEquals(seqs.size(), back.size());
        for (int i = 0; i < seqs.size(); i++) {
            assertArrayEquals(seqs.get(i), back.get(i),
                "slice round-trip @ read " + i);
        }
    }

    // ── Task 23: top-level + canonical fixtures ─────────────────────

    private record FixtureInputs(
        List<byte[]> sequences,
        List<String> cigars,
        long[] positions,
        byte[] ref,
        byte[] md5,
        String uri
    ) { }

    private static FixtureInputs fixtureA() {
        byte[] ref = repeat("ACGT", 250);  // 1000bp
        List<byte[]> seqs = new ArrayList<>();
        List<String> cigars = new ArrayList<>();
        long[] positions = new long[100];
        for (int i = 0; i < 100; i++) {
            seqs.add(repeat("ACGTACGTAC", 10));
            cigars.add("100M");
            positions[i] = 1;
        }
        return new FixtureInputs(seqs, cigars, positions, ref,
            md5(ref), "fixture_a_uri");
    }

    private static FixtureInputs fixtureB() {
        byte[] ref = repeat("ACGT", 250);
        byte[] base = repeat("ACGTACGTAC", 10);
        List<byte[]> seqs = new ArrayList<>();
        List<String> cigars = new ArrayList<>();
        long[] positions = new long[200];
        for (int i = 0; i < 200; i++) {
            byte[] s = base.clone();
            int idx = i % 100;
            s[idx] = (s[idx] != (byte) 'C') ? (byte) 'C' : (byte) 'G';
            seqs.add(s);
            cigars.add("100M");
            positions[i] = 1;
        }
        return new FixtureInputs(seqs, cigars, positions, ref,
            md5(ref), "fixture_b_uri");
    }

    private static FixtureInputs fixtureC() {
        byte[] ref = repeat("ACGTACGTAC", 100);
        byte[][] seqsTpl = {
            "NNACGTACGTAC".getBytes(StandardCharsets.US_ASCII),  // 2S10M = 12 bytes
            "ACGTNNACGTAC".getBytes(StandardCharsets.US_ASCII),  // 4M2I6M = 12 bytes
            "ACGTAGTACG".getBytes(StandardCharsets.US_ASCII),    // 5M2D5M = 10 bytes
        };
        String[] cigarsTpl = {"2S10M", "4M2I6M", "5M2D5M"};
        List<byte[]> seqs = new ArrayList<>(30);
        List<String> cigars = new ArrayList<>(30);
        long[] positions = new long[30];
        for (int i = 0; i < 30; i++) {
            seqs.add(seqsTpl[i % 3]);
            cigars.add(cigarsTpl[i % 3]);
            positions[i] = 1;
        }
        return new FixtureInputs(seqs, cigars, positions, ref,
            md5(ref), "fixture_c_uri");
    }

    private static FixtureInputs fixtureD() {
        byte[] ref = repeat("ACGT", 1000);
        List<byte[]> seqs = List.of(new byte[]{'A'});
        List<String> cigars = List.of("1M");
        long[] positions = {1};
        return new FixtureInputs(seqs, cigars, positions, ref,
            md5(ref), "fixture_d_uri");
    }

    private static void assertFixture(String name, FixtureInputs in)
            throws IOException {
        byte[] expected = loadFixture(name);
        byte[] encoded = RefDiff.encode(
            in.sequences(), in.cigars(), in.positions(),
            in.ref(), in.md5(), in.uri());
        assertArrayEquals(expected, encoded,
            name + ": Java encode() must match Python fixture byte-exact");
        // Decode the fixture and verify each per-read sequence.
        List<byte[]> back = RefDiff.decode(expected, in.cigars(),
            in.positions(), in.ref());
        assertEquals(in.sequences().size(), back.size(),
            name + ": decoded read count");
        for (int i = 0; i < in.sequences().size(); i++) {
            assertArrayEquals(in.sequences().get(i), back.get(i),
                name + ": decoded read @ " + i);
        }
    }

    @Test
    void canonicalFixtureA() throws IOException {
        assertFixture("ref_diff_a.bin", fixtureA());
    }

    @Test
    void canonicalFixtureB() throws IOException {
        assertFixture("ref_diff_b.bin", fixtureB());
    }

    @Test
    void canonicalFixtureC() throws IOException {
        assertFixture("ref_diff_c.bin", fixtureC());
    }

    @Test
    void canonicalFixtureD() throws IOException {
        assertFixture("ref_diff_d.bin", fixtureD());
    }
}
