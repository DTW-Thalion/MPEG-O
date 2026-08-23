/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.hdf5.Hdf5File;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Qualities V5 (sequence context): umbrella dispatch, the writer gate,
 * reader ordering, and the shared golden decode fixture (Python:
 * test_qualities_v5.py; ObjC: TestQualitiesV5.m).
 */
class QualitiesV5Test {

    /** Quality is a function of the current base plus 2 bits of noise
     *  with i.i.d. bases, the shape sequence context exists for. */
    private static byte[][] motifCorpus(int nReads, int len) {
        byte[] bases = {'A', 'C', 'G', 'T'};
        Random r = new Random(7);
        byte[] seq = new byte[nReads * len];
        byte[] qual = new byte[nReads * len];
        for (int i = 0; i < seq.length; i++) {
            int bi = r.nextInt(4);
            seq[i] = bases[bi];
            qual[i] = (byte) (40 + 10 * bi + r.nextInt(4));
        }
        return new byte[][]{qual, seq};
    }

    private static int[] fill(int n, int v) {
        int[] a = new int[n];
        java.util.Arrays.fill(a, v);
        return a;
    }

    @Test
    void v5EmittedAndSmaller() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] v4 = FqzcompNx16Z.encode(c[0], lens, flags);
        byte[] v5 = FqzcompNx16Z.encode(c[0], lens, flags, c[1]);
        assertEquals(4, v4[4]);
        assertEquals(5, v5[4]);
        assertTrue(v5.length < v4.length);
    }

    @Test
    void nullSequencesIsByteIdenticalV4() {
        byte[][] c = motifCorpus(2000, 100);
        int[] lens = fill(2000, 100), flags = fill(2000, 0);
        assertArrayEquals(FqzcompNx16Z.encode(c[0], lens, flags),
                          FqzcompNx16Z.encode(c[0], lens, flags, (byte[]) null));
    }

    @Test
    void v5RoundTrips() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] blob = FqzcompNx16Z.encode(c[0], lens, flags, c[1]);
        var dr = FqzcompNx16Z.decode(blob, flags, () -> c[1]);
        assertArrayEquals(c[0], dr.qualities());
        assertArrayEquals(lens, dr.readLengths());
    }

    @Test
    void v5WithoutSequencesThrows() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] blob = FqzcompNx16Z.encode(c[0], lens, flags, c[1]);
        assertEquals(5, blob[4]);
        assertThrows(IllegalStateException.class,
            () -> FqzcompNx16Z.decode(blob, flags));
    }

    @Test
    void smallChannelStaysV4() {
        byte[][] c = motifCorpus(300, 100);
        int[] lens = fill(300, 100), flags = fill(300, 0);
        assertEquals(4, FqzcompNx16Z.encode(c[0], lens, flags, c[1])[4]);
    }

    @Test
    void encodeLengthMismatchThrows() {
        byte[][] c = motifCorpus(300, 100);
        int[] lens = fill(300, 100), flags = fill(300, 0);
        byte[] shortSeq = java.util.Arrays.copyOf(c[1], c[1].length - 1);
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16Z.encode(c[0], lens, flags, shortSeq));
    }

    @Test
    void hintV4AutoIgnoresSequences() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] pinned = FqzcompNx16Z.encode(c[0], lens, flags, c[1],
            new FqzcompNx16Z.EncodeOptions()
                .v4StrategyHint(FqzcompNx16Z.HINT_V4_AUTO));
        assertArrayEquals(FqzcompNx16Z.encode(c[0], lens, flags), pinned);
    }

    @Test
    void streamStrategySniffer() {
        byte[][] c = motifCorpus(300, 100);
        int[] lens = fill(300, 100), flags = fill(300, 0);
        byte[] v4 = FqzcompNx16Z.encode(c[0], lens, flags);
        assertEquals(4, FqzcompNx16Z.streamStrategy(v4));
        byte[] s5 = FqzcompNx16Z.encode(c[0], lens, flags, c[1],
            new FqzcompNx16Z.EncodeOptions().v4StrategyHint(5));
        assertEquals(5, FqzcompNx16Z.streamStrategy(s5));
        byte[] s6 = FqzcompNx16Z.encode(c[0], lens, flags, c[1],
            new FqzcompNx16Z.EncodeOptions().v4StrategyHint(6));
        assertEquals(6, FqzcompNx16Z.streamStrategy(s6));
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16Z.streamStrategy(new byte[]{'X', 'X'}));
    }

    @Test
    void goldenFixtureDecodes() throws Exception {
        byte[] blob = res("/ttio/fixtures/qualities_v5_golden.bin");
        byte[] seq = res("/ttio/fixtures/qualities_v5_golden_seq.bin");
        byte[] expected = res("/ttio/fixtures/qualities_v5_golden_qual.bin");
        var dr = FqzcompNx16Z.decode(blob, fill(300, 0), () -> seq);
        assertArrayEquals(expected, dr.qualities());
        assertArrayEquals(fill(300, 100), dr.readLengths());
    }

    private static byte[] res(String p) throws Exception {
        try (var in = QualitiesV5Test.class.getResourceAsStream(p)) {
            assertNotNull(in, p);
            return in.readAllBytes();
        }
    }

    // ── File level ──────────────────────────────────────────────────

    private static WrittenGenomicRun makeRun(int nReads, int readLen,
                                             boolean disable) {
        byte[][] c = motifCorpus(nReads, readLen);
        long[] positions = new long[nReads];
        byte[] mapqs = new byte[nReads];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[nReads];
        long[] offsets = new long[nReads];
        int[] lengths = new int[nReads];
        List<String> cigars = new ArrayList<>(nReads);
        List<String> readNames = new ArrayList<>(nReads);
        List<String> mateChroms = new ArrayList<>(nReads);
        List<String> chroms = new ArrayList<>(nReads);
        long[] matePos = new long[nReads];
        int[] tlens = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            positions[i] = 10_000L + i * 100L;
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
            cigars.add(readLen + "M");
            readNames.add(String.format("read_%06d", i));
            mateChroms.add("*");
            chroms.add("chr1");
            matePos[i] = -1L;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "V5_TEST",
            positions, mapqs, flags, c[1], c[0], offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            Compression.NONE,
            Map.of("qualities", Compression.FQZCOMP_NX16_Z),
            List.of(), false, null, null, null, disable);
    }

    private static Path writeRun(Path tmp, WrittenGenomicRun run,
                                 String fname) {
        Path file = tmp.resolve(fname);
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    private static int qualitiesVersionByte(Path file) throws Exception {
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             var root = f.rootGroup();
             var study = root.openGroup("study");
             var gRuns = study.openGroup("genomic_runs");
             var rg = gRuns.openGroup("genomic_0001");
             var sc = rg.openGroup("signal_channels");
             var ds = sc.openDataset("qualities")) {
            byte[] blob = (byte[]) ds.readData();
            return blob[4] & 0xFF;
        }
    }

    @Test
    void fileRoundTripV5(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = makeRun(11000, 100, false);
        byte[] expectedQual = run.qualities().clone();
        Path file = writeRun(tmp, run, "v5.tio");
        assertEquals(5, qualitiesVersionByte(file));
        try (var ds = SpectralDataset.open(file.toString())) {
            var gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            StringBuilder got = new StringBuilder();
            for (int i = 0; i < 3; i++) {
                got.append(new String(gr.readAt(i).qualities(),
                        java.nio.charset.StandardCharsets.ISO_8859_1));
            }
            String expected = new String(expectedQual, 0, 300,
                    java.nio.charset.StandardCharsets.ISO_8859_1);
            assertEquals(expected, got.toString());
        }
    }

    @Test
    void optDisableStaysV4(@TempDir Path tmp) throws Exception {
        Path file = writeRun(tmp, makeRun(11000, 100, true), "v4.tio");
        assertEquals(4, qualitiesVersionByte(file));
    }

    @Test
    void v6RoundTripsAndSniffs() {
        byte[][] c = motifCorpus(2000, 100);
        int[] lens = fill(2000, 100), flags = fill(2000, 0);
        byte[] v6 = FqzcompNx16Z.encode(c[0], lens, flags,
            new FqzcompNx16Z.EncodeOptions()
                .v4StrategyHint(FqzcompNx16Z.HINT_V6));
        assertEquals(6, v6[4]);
        assertEquals(8, FqzcompNx16Z.streamStrategy(v6));
        FqzcompNx16Z.DecodeResult dr = FqzcompNx16Z.decode(v6, flags, null);
        assertArrayEquals(c[0], dr.qualities());
    }

    /** The width reaches the stream through setV6Sbits, and a decoder
     *  needs the sequences only because the stream says so. Python:
     *  test_v6_sequence_context_round_trips_and_shrinks; Objective-C:
     *  TestQualitiesV5.m. */
    @Test
    void v6SequenceContextRoundTrips() {
        byte[][] c = motifCorpus(2000, 100);
        int[] lens = fill(2000, 100), flags = fill(2000, 0);
        assertEquals(0, FqzcompNx16Z.getV6Sbits());
        byte[] plain = FqzcompNx16Z.encode(c[0], lens, flags,
            new FqzcompNx16Z.EncodeOptions()
                .v4StrategyHint(FqzcompNx16Z.HINT_V6));
        try {
            FqzcompNx16Z.setV6Sbits(4);
            assertEquals(4, FqzcompNx16Z.getV6Sbits());
            byte[] withSeq = FqzcompNx16Z.encode(c[0], lens, flags, c[1],
                new FqzcompNx16Z.EncodeOptions()
                    .v4StrategyHint(FqzcompNx16Z.HINT_V6));
            assertEquals(6, withSeq[4]);
            assertArrayEquals(c[0],
                FqzcompNx16Z.decode(withSeq, flags, () -> c[1]).qualities());
            assertTrue(withSeq.length < plain.length,
                       "the field pays where quality follows the base");

            FqzcompNx16Z.setV6Sbits(FqzcompNx16Z.V6_SBITS_AUTO);
            byte[] auto = FqzcompNx16Z.encode(c[0], lens, flags, c[1],
                new FqzcompNx16Z.EncodeOptions()
                    .v4StrategyHint(FqzcompNx16Z.HINT_V6));
            assertArrayEquals(c[0],
                FqzcompNx16Z.decode(auto, flags, () -> c[1]).qualities());
            assertTrue(auto.length <= plain.length,
                       "0 is a candidate, so auto never loses to it");
        } finally {
            FqzcompNx16Z.setV6Sbits(0);
        }
        /* Width 0 is what every stream written before the field carried. */
        assertArrayEquals(c[0], FqzcompNx16Z.decode(plain, flags).qualities());
    }

    @Test
    void v6DecodesWithoutSequencesOverload() {
        byte[][] c = motifCorpus(2000, 100);
        int[] lens = fill(2000, 100), flags = fill(2000, 0);
        byte[] v6 = FqzcompNx16Z.encode(c[0], lens, flags,
            new FqzcompNx16Z.EncodeOptions()
                .v4StrategyHint(FqzcompNx16Z.HINT_V6));
        FqzcompNx16Z.DecodeResult dr = FqzcompNx16Z.decode(v6, flags);
        assertArrayEquals(c[0], dr.qualities());
    }

    @Test
    void v6GoldenFixtureDecodes() throws Exception {
        byte[] blob = res("/ttio/fixtures/qualities_v6_golden.bin");
        byte[] expected = res("/ttio/fixtures/qualities_v6_golden_qual.bin");
        assertEquals(6, blob[4]);
        FqzcompNx16Z.DecodeResult dr =
            FqzcompNx16Z.decode(blob, new int[300]);
        assertArrayEquals(expected, dr.qualities());
    }
}
