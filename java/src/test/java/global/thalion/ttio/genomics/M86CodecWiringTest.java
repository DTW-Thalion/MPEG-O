/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.hdf5.Hdf5Dataset;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M86 — Java acceptance tests for genomic signal-channel codec wiring.
 *
 * <p>Mirrors the Python {@code test_m86_genomic_codec_wiring.py} suite
 * one-for-one (11 cases). Cross-language fixtures shipped under
 * {@code src/test/resources/ttio/fixtures/genomic/m86_codec_*.tio} are
 * verbatim copies of the Python originals — the final test asserts
 * byte-exact round-trip from the Python writer to the Java reader.</p>
 */
class M86CodecWiringTest {

    // ── Fixture helpers ───────────────────────────────────────────

    private static final int N_READS    = 10;
    private static final int READ_LEN   = 100;
    private static final int TOTAL      = N_READS * READ_LEN;     // 1000

    /** Pure-ACGT sequence: 1000 bytes, "ACGT" repeated. */
    private static byte[] pureAcgt() {
        byte[] out = new byte[TOTAL];
        byte[] cycle = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < TOTAL; i++) out[i] = cycle[i % 4];
        return out;
    }

    /** Phred 30..40 cycle for {@code TOTAL} bytes (matches Python fixture). */
    private static byte[] phredCycle() {
        byte[] out = new byte[TOTAL];
        for (int i = 0; i < TOTAL; i++) out[i] = (byte) (30 + (i % 11));
        return out;
    }

    /** Illumina-8 bin centres (Phase D): {0,5,15,22,27,32,37,40}. */
    private static final byte[] BIN_CENTRES = {0, 5, 15, 22, 27, 32, 37, 40};

    /** Bin-centre Phred buffer: {@code BIN_CENTRES} cycled to {@code TOTAL}
     *  bytes. Mirrors Python {@code QUAL_BIN_CENTRE} (1000 bytes for 10
     *  reads × 100 bp). Bin centres round-trip byte-exact through
     *  QUALITY_BINNED. */
    private static byte[] qualBinCentre() {
        byte[] out = new byte[TOTAL];
        for (int i = 0; i < TOTAL; i++) out[i] = BIN_CENTRES[i % BIN_CENTRES.length];
        return out;
    }

    /** Deterministic Illumina-style names — same generator as the
     *  Python reference and the cross-language fixture input.
     *  Tokenises to ["INSTR:RUN:", N, ":", N, ":", N, ":", N] — 7
     *  alternating string/numeric columns that pack tightly through
     *  the NAME_TOKENIZED columnar mode. */
    private static List<String> illuminaNames(int n) {
        List<String> out = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            out.add(String.format("INSTR:RUN:1:%d:%d:%d", i / 4, i % 4, i * 100));
        }
        return out;
    }

    /** 10-read × 100-bp synthetic genomic run, mirrors Python {@code _make_run}. */
    private static WrittenGenomicRun makeRun(byte[] seq, byte[] qual,
                                              Map<String, Compression> overrides) {
        return makeRunWithNames(seq, qual, defaultReadNames(), overrides);
    }

    /** Default read-name list used by the legacy test cases ("r0".."r9"). */
    private static List<String> defaultReadNames() {
        List<String> out = new ArrayList<>(N_READS);
        for (int i = 0; i < N_READS; i++) out.add("r" + i);
        return out;
    }

    /** 10-read × 100-bp synthetic genomic run with caller-supplied
     *  read names. Mirrors Python {@code _make_run_with_names} — used
     *  by the M86 Phase E tests to exercise the structured-Illumina
     *  columnar encode path. */
    private static WrittenGenomicRun makeRunWithNames(byte[] seq, byte[] qual,
                                              List<String> readNames,
                                              Map<String, Compression> overrides) {
        assertEquals(TOTAL, seq.length, "seq length");
        assertEquals(TOTAL, qual.length, "qual length");
        assertEquals(N_READS, readNames.size(), "readNames length");
        long[] positions = new long[N_READS];
        for (int i = 0; i < N_READS; i++) positions[i] = i * 1000L;
        byte[] mapqs = new byte[N_READS];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags  = new int[N_READS];      // zero
        long[] offsets = new long[N_READS];
        int[]  lengths = new int[N_READS];
        for (int i = 0; i < N_READS; i++) {
            offsets[i] = (long) i * READ_LEN;
            lengths[i] = READ_LEN;
        }
        List<String> cigars = new ArrayList<>(N_READS);
        List<String> mateChroms = new ArrayList<>(N_READS);
        List<String> chroms     = new ArrayList<>(N_READS);
        long[] matePos = new long[N_READS];
        int[] tlens    = new int[N_READS];
        for (int i = 0; i < N_READS; i++) {
            cigars.add("100M");
            mateChroms.add("chr1");
            chroms.add("chr1");
            matePos[i] = -1L;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "M86_TEST",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            // Use NONE for the default compression so the M86 size-win
            // baseline (test #10) is a clean uncompressed reference;
            // overrides are still independent per Gotcha §99.
            Compression.NONE,
            overrides == null ? Map.of() : overrides);
    }

    private static Path writeRun(Path tmp, WrittenGenomicRun run, String fname) {
        Path file = tmp.resolve(fname);
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    /** Per-read sequence slice as ASCII string. */
    private static String expectedSeqSlice(byte[] seq, int i) {
        return new String(seq, i * READ_LEN, READ_LEN, StandardCharsets.US_ASCII);
    }

    /** Per-read quality slice as raw bytes. */
    private static byte[] expectedQualSlice(byte[] qual, int i) {
        byte[] out = new byte[READ_LEN];
        System.arraycopy(qual, i * READ_LEN, out, 0, READ_LEN);
        return out;
    }

    /** Copy a JAR resource fixture to a temp file (HDF5 needs a real path). */
    private static Path copyFixtureToTemp(String name) throws IOException {
        Path tmp = Files.createTempFile("ttio-m86-", ".tio");
        try (InputStream in = M86CodecWiringTest.class
                .getResourceAsStream("/ttio/fixtures/genomic/" + name)) {
            if (in == null) throw new FileNotFoundException(name);
            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
        }
        return tmp;
    }

    // ── 1. Round-trip sequences via rANS order-0 ────────────────────

    @Test
    void roundTripSequencesRansOrder0(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
            Map.of("sequences", Compression.RANS_ORDER0));
        Path file = writeRun(tmp, run, "r0.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(N_READS, gr.readCount());
            byte[] seq  = pureAcgt();
            byte[] qual = phredCycle();
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "rANS order-0 round-trip @ read " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "qualities (no override) @ read " + i);
            }
        }
    }

    // ── 2. Round-trip sequences via rANS order-1 ────────────────────

    @Test
    void roundTripSequencesRansOrder1(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
            Map.of("sequences", Compression.RANS_ORDER1));
        Path file = writeRun(tmp, run, "r1.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            byte[] seq = pureAcgt();
            for (int i = 0; i < N_READS; i++) {
                assertEquals(expectedSeqSlice(seq, i), gr.readAt(i).sequence(),
                    "rANS order-1 round-trip @ read " + i);
            }
        }
    }

    // ── 3. Round-trip sequences via BASE_PACK ──────────────────────

    @Test
    void roundTripSequencesBasePack(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
            Map.of("sequences", Compression.BASE_PACK));
        Path file = writeRun(tmp, run, "bp.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            byte[] seq = pureAcgt();
            for (int i = 0; i < N_READS; i++) {
                assertEquals(expectedSeqSlice(seq, i), gr.readAt(i).sequence(),
                    "BASE_PACK round-trip @ read " + i);
            }
        }
    }

    // ── 4. Round-trip qualities via rANS order-1 ───────────────────

    @Test
    void roundTripQualitiesRansOrder1(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
            Map.of("qualities", Compression.RANS_ORDER1));
        Path file = writeRun(tmp, run, "q-r1.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            byte[] qual = phredCycle();
            for (int i = 0; i < N_READS; i++) {
                assertArrayEquals(expectedQualSlice(qual, i),
                    gr.readAt(i).qualities(),
                    "qualities rANS order-1 round-trip @ read " + i);
            }
        }
    }

    // ── 5. Mixed: sequences=BASE_PACK, qualities=RANS_ORDER1 ───────

    @Test
    void roundTripMixed(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
            Map.of("sequences", Compression.BASE_PACK,
                   "qualities", Compression.RANS_ORDER1));
        Path file = writeRun(tmp, run, "mixed.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            byte[] seq  = pureAcgt();
            byte[] qual = phredCycle();
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "mixed sequences @ " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "mixed qualities @ " + i);
            }
        }
    }

    // ── 6. Back-compat: empty overrides path unchanged ─────────────

    @Test
    void backCompatNoOverrides(@TempDir Path tmp) {
        // Use ZLIB default to exercise the HDF5-filter pipeline.
        byte[] seq  = pureAcgt();
        byte[] qual = phredCycle();
        WrittenGenomicRun run = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "M86_TEST",
            new long[N_READS], new byte[N_READS], new int[N_READS],
            seq, qual,
            offsets(), lengths(),
            cigars(), readNames(), chr1List(), new long[N_READS], new int[N_READS],
            chr1List(), Compression.ZLIB);
        Path file = writeRun(tmp, run, "nocodec.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "back-compat sequences @ " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "back-compat qualities @ " + i);
            }
        }
    }

    // Local helpers shared by the back-compat constructor.
    private static long[] offsets() {
        long[] o = new long[N_READS];
        for (int i = 0; i < N_READS; i++) o[i] = (long) i * READ_LEN;
        return o;
    }
    private static int[] lengths() {
        int[] l = new int[N_READS];
        java.util.Arrays.fill(l, READ_LEN);
        return l;
    }
    private static List<String> cigars() {
        List<String> l = new ArrayList<>(N_READS);
        for (int i = 0; i < N_READS; i++) l.add("100M");
        return l;
    }
    private static List<String> readNames() {
        List<String> l = new ArrayList<>(N_READS);
        for (int i = 0; i < N_READS; i++) l.add("r" + i);
        return l;
    }
    private static List<String> chr1List() {
        List<String> l = new ArrayList<>(N_READS);
        for (int i = 0; i < N_READS; i++) l.add("chr1");
        return l;
    }

    // ── 7. Reject invalid channel ──────────────────────────────────

    @Test
    void rejectInvalidChannel(@TempDir Path tmp) {
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("positions", Compression.RANS_ORDER0));
                writeRun(tmp, bad, "bad-channel.tio");
            });
        assertTrue(ex.getMessage().contains("positions"),
            "error message should name the offending channel: " + ex.getMessage());
        assertTrue(ex.getMessage().contains("sequences"),
            "error message should hint at allowed channels: " + ex.getMessage());
    }

    // ── 8. Reject invalid codec ────────────────────────────────────

    @Test
    void rejectInvalidCodec(@TempDir Path tmp) {
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("sequences", Compression.LZ4));
                writeRun(tmp, bad, "bad-codec.tio");
            });
        assertTrue(ex.getMessage().contains("LZ4"),
            "error message should name the offending codec: " + ex.getMessage());
    }

    // ── 9. @compression attribute set correctly ────────────────────

    @Test
    void attributeSetCorrectly(@TempDir Path tmp) {
        for (Compression codec : new Compression[]{
                Compression.RANS_ORDER0,
                Compression.RANS_ORDER1,
                Compression.BASE_PACK}) {
            WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
                Map.of("sequences", codec));
            Path file = writeRun(tmp, run, "attr-" + codec.name() + ".tio");
            // Probe via the low-level Hdf5 API so we read the actual
            // on-disk uint8 attribute, not a Java cache.
            try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
                 Hdf5Group root = f.rootGroup();
                 Hdf5Group study = root.openGroup("study");
                 Hdf5Group gRuns = study.openGroup("genomic_runs");
                 Hdf5Group rg    = gRuns.openGroup("genomic_0001");
                 Hdf5Group sc    = rg.openGroup("signal_channels");
                 Hdf5Dataset seqDs  = sc.openDataset("sequences");
                 Hdf5Dataset qualDs = sc.openDataset("qualities")) {
                assertTrue(seqDs.hasAttribute("compression"),
                    "@compression must be set for codec " + codec);
                long val = seqDs.readIntegerAttribute("compression", -1L);
                assertEquals(codec.ordinal(), val,
                    "@compression value for " + codec);
                // qualities is not in the override map → no attribute.
                assertFalse(qualDs.hasAttribute("compression"),
                    "qualities should have no @compression attribute "
                    + "(uncompressed channels write nothing)");
            }
        }
    }

    // ── 10. Size-win: BASE_PACK on pure-ACGT < 30% raw ─────────────

    @Test
    void sizeWinBasePack(@TempDir Path tmp) {
        // 100 000 bases pure-ACGT for a real size-win measurement.
        int n = 1000, len = 100;
        byte[] seq = new byte[n * len];
        byte[] cycle = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < seq.length; i++) seq[i] = cycle[i % 4];
        byte[] qual = new byte[n * len];
        java.util.Arrays.fill(qual, (byte) 30);

        WrittenGenomicRun base = bigRun(n, len, seq, qual, Map.of());
        WrittenGenomicRun packed = bigRun(n, len, seq, qual,
            Map.of("sequences", Compression.BASE_PACK));

        Path baseFile   = writeRun(tmp, base,   "size-base.tio");
        Path packedFile = writeRun(tmp, packed, "size-bp.tio");

        long baseSeqBytes;
        long packedSeqBytes;
        try (Hdf5File f = Hdf5File.openReadOnly(baseFile.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset seqDs = sc.openDataset("sequences")) {
            baseSeqBytes = seqDs.getLength();
        }
        try (Hdf5File f = Hdf5File.openReadOnly(packedFile.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset seqDs = sc.openDataset("sequences")) {
            packedSeqBytes = seqDs.getLength();
        }

        double ratio = (double) packedSeqBytes / (double) baseSeqBytes;
        assertTrue(ratio < 0.30,
            "BASE_PACK sequences dataset should be < 30% of uncompressed; "
            + "got " + packedSeqBytes + " / " + baseSeqBytes
            + " = " + String.format("%.4f", ratio));
        assertTrue(packedSeqBytes > 0, "BASE_PACK output non-empty");

        // Confirm the read path still returns the original bases.
        try (SpectralDataset ds = SpectralDataset.open(packedFile.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            AlignedRead r0 = gr.readAt(0);
            assertEquals(len, r0.sequence().length(),
                "decoded read length matches input");
            // Spot-check a middle read.
            AlignedRead r500 = gr.readAt(500);
            String expected = new String(seq, 500 * len, len, StandardCharsets.US_ASCII);
            assertEquals(expected, r500.sequence(),
                "BASE_PACK round-trip on 100k-base channel");
        }
    }

    /** Build a larger run for the size-win test. */
    private static WrittenGenomicRun bigRun(int n, int len, byte[] seq, byte[] qual,
                                            Map<String, Compression> overrides) {
        long[] positions = new long[n];
        for (int i = 0; i < n; i++) positions[i] = i * 1000L;
        byte[] mapqs = new byte[n];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * len;
            lengths[i] = len;
        }
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(len + "M");
            readNames.add("r" + i);
            mateChroms.add("chr1");
            chroms.add("chr1");
            matePos[i] = -1L;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "M86_BIG",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            Compression.NONE, overrides);
    }

    // ── 11. Cross-language fixtures (Python → Java byte-exact) ─────

    @Test
    void crossLanguageFixtures() throws IOException {
        // Each fixture used overrides {sequences: <codec>, qualities: <codec>}
        // on input PURE_ACGT_SEQ + PHRED_CYCLE_QUAL (HANDOFF.md §6.2).
        String[] fixtures = {
            "m86_codec_rans_order0.tio",
            "m86_codec_rans_order1.tio",
            "m86_codec_base_pack.tio",
        };
        byte[] expectedSeq  = pureAcgt();
        byte[] expectedQual = phredCycle();
        for (String name : fixtures) {
            Path tmp = copyFixtureToTemp(name);
            try (SpectralDataset ds = SpectralDataset.open(tmp.toString())) {
                GenomicRun gr = ds.genomicRuns().get("genomic_0001");
                assertNotNull(gr, "fixture " + name + " has genomic_0001");
                assertEquals(N_READS, gr.readCount(), "read count for " + name);
                for (int i = 0; i < N_READS; i++) {
                    AlignedRead r = gr.readAt(i);
                    assertEquals(expectedSeqSlice(expectedSeq, i), r.sequence(),
                        name + " seq @ " + i);
                    assertArrayEquals(expectedQualSlice(expectedQual, i),
                        r.qualities(), name + " qual @ " + i);
                }
            } finally {
                try { Files.deleteIfExists(tmp); } catch (IOException ignored) {}
            }
        }
    }

    // ── 12. Phase D: round-trip qualities via QUALITY_BINNED (centres) ──

    @Test
    void roundTripQualitiesQualityBinned(@TempDir Path tmp) {
        // Bin-centre Phred values round-trip byte-exact through
        // QUALITY_BINNED (the codec is lossy in general, but inputs at
        // bin centres 0/5/15/22/27/32/37/40 decode back to themselves).
        byte[] qual = qualBinCentre();
        WrittenGenomicRun run = makeRun(pureAcgt(), qual,
            Map.of("qualities", Compression.QUALITY_BINNED));
        Path file = writeRun(tmp, run, "qb-centres.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(N_READS, gr.readCount());
            byte[] seq = pureAcgt();
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "QUALITY_BINNED bin-centre seq @ read " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "QUALITY_BINNED bin-centre qual @ read " + i);
            }
        }
    }

    // ── 13. Phase D: lossy round-trip of arbitrary Phred values ────

    @Test
    void roundTripQualitiesQualityBinnedLossy(@TempDir Path tmp) {
        // Arbitrary Phred values cycled 0..49 — covers every bin and
        // the saturation case (>=40 → centre 40). Use the codec's own
        // encode/decode round-trip to compute the expected lossy
        // mapping rather than reimplementing the bin table.
        byte[] arbitraryQual = new byte[TOTAL];
        for (int i = 0; i < TOTAL; i++) arbitraryQual[i] = (byte) (i % 50);
        byte[] expectedQual = global.thalion.ttio.codecs.Quality.decode(
            global.thalion.ttio.codecs.Quality.encode(arbitraryQual));
        assertEquals(TOTAL, expectedQual.length, "expected lossy length");
        // Sanity check: lossy mapping must actually differ from input.
        assertFalse(java.util.Arrays.equals(expectedQual, arbitraryQual),
            "lossy mapping must differ from input, else test is degenerate");

        WrittenGenomicRun run = makeRun(pureAcgt(), arbitraryQual,
            Map.of("qualities", Compression.QUALITY_BINNED));
        Path file = writeRun(tmp, run, "qb-lossy.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            byte[] seq = pureAcgt();
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "QUALITY_BINNED lossy seq @ read " + i);
                assertArrayEquals(expectedQualSlice(expectedQual, i),
                    r.qualities(),
                    "read " + i + ": qualities did not match lossy mapping");
            }
        }
    }

    // ── 14. Phase D: size-win — QUALITY_BINNED qualities < 55% raw ─

    @Test
    void sizeWinQualityBinned(@TempDir Path tmp) {
        // 100 000 bytes of bin-centre qualities → wire stream is
        // 6 + 50 000 = 50 006 bytes (≈ 50.006% ratio). Use the
        // 0.55 target from the Python equivalent.
        int n = 1000, len = 100;
        byte[] seq = new byte[n * len];
        byte[] cycle = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < seq.length; i++) seq[i] = cycle[i % 4];
        byte[] qual = new byte[n * len];
        for (int i = 0; i < qual.length; i++)
            qual[i] = BIN_CENTRES[i % BIN_CENTRES.length];

        WrittenGenomicRun base = bigRun(n, len, seq, qual, Map.of());
        WrittenGenomicRun qbRun = bigRun(n, len, seq, qual,
            Map.of("qualities", Compression.QUALITY_BINNED));

        Path baseFile = writeRun(tmp, base,  "qb-size-base.tio");
        Path qbFile   = writeRun(tmp, qbRun, "qb-size-compressed.tio");

        long baseQualBytes;
        long qbQualBytes;
        try (Hdf5File f = Hdf5File.openReadOnly(baseFile.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset qDs = sc.openDataset("qualities")) {
            baseQualBytes = qDs.getLength();
        }
        try (Hdf5File f = Hdf5File.openReadOnly(qbFile.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset qDs = sc.openDataset("qualities")) {
            qbQualBytes = qDs.getLength();
        }

        double ratio = (double) qbQualBytes / (double) baseQualBytes;
        assertTrue(ratio < 0.55,
            "QUALITY_BINNED qualities dataset should be < 55% of "
            + "uncompressed; got " + qbQualBytes + " / " + baseQualBytes
            + " = " + String.format("%.4f", ratio));
        assertTrue(qbQualBytes > 0, "QUALITY_BINNED output non-empty");
    }

    // ── 15. Phase D: @compression == 7 set on the qualities dataset ─

    @Test
    void attributeSetCorrectlyQualityBinned(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(pureAcgt(), qualBinCentre(),
            Map.of("qualities", Compression.QUALITY_BINNED));
        Path file = writeRun(tmp, run, "qb-attr.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset seqDs  = sc.openDataset("sequences");
             Hdf5Dataset qualDs = sc.openDataset("qualities")) {
            // qualities must carry @compression == 7.
            assertTrue(qualDs.hasAttribute("compression"),
                "qualities must carry @compression for QUALITY_BINNED");
            long val = qualDs.readIntegerAttribute("compression", -1L);
            assertEquals(Compression.QUALITY_BINNED.ordinal(), val,
                "@compression value must be 7 (QUALITY_BINNED)");
            assertEquals(7L, val,
                "QUALITY_BINNED is M79 codec id 7");
            // sequences is not in the override map → no attribute.
            assertFalse(seqDs.hasAttribute("compression"),
                "sequences must have no @compression attribute");
        }
    }

    // ── 16. Phase D: reject QUALITY_BINNED on sequences ────────────

    @Test
    void rejectQualityBinnedOnSequences(@TempDir Path tmp) {
        // Per Binding Decision §108, applying QUALITY_BINNED to ACGT
        // bytes would map all four to bin 7 (centre 40). Validation
        // throws IllegalArgumentException at write time; the message
        // must name the codec, the channel, and the lossy rationale.
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), qualBinCentre(),
                    Map.of("sequences", Compression.QUALITY_BINNED));
                writeRun(tmp, bad, "bad-qb-seq.tio");
            });
        String msg = ex.getMessage();
        assertNotNull(msg, "exception must have a message");
        assertTrue(msg.contains("QUALITY_BINNED"),
            "error must name the codec; got: " + msg);
        assertTrue(msg.contains("sequences"),
            "error must name the channel; got: " + msg);
        assertTrue(msg.toLowerCase(java.util.Locale.ROOT).contains("lossy"),
            "error must explain that quality binning is lossy; got: " + msg);
        assertTrue(msg.contains("Phred")
                || msg.toLowerCase(java.util.Locale.ROOT).contains("quality"),
            "error must mention Phred/quality scores; got: " + msg);
    }

    // ── 17. Phase D: mixed BASE_PACK seq + QUALITY_BINNED qual ─────

    @Test
    void mixedQualityBinnedWithRans(@TempDir Path tmp) {
        // Per-channel codec dispatch on both byte channels, two
        // different codec ids in one run (BASE_PACK = 6, QUALITY_BINNED
        // = 7). Bin-centre qualities round-trip byte-exact.
        byte[] seq = pureAcgt();
        byte[] qual = qualBinCentre();
        WrittenGenomicRun run = makeRun(seq, qual,
            Map.of("sequences", Compression.BASE_PACK,
                   "qualities", Compression.QUALITY_BINNED));
        Path file = writeRun(tmp, run, "qb-mixed.tio");

        // Verify both channels carry their respective codec ids.
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset seqDs  = sc.openDataset("sequences");
             Hdf5Dataset qualDs = sc.openDataset("qualities")) {
            assertEquals(Compression.BASE_PACK.ordinal(),
                seqDs.readIntegerAttribute("compression", -1L),
                "sequences @compression == BASE_PACK (6)");
            assertEquals(Compression.QUALITY_BINNED.ordinal(),
                qualDs.readIntegerAttribute("compression", -1L),
                "qualities @compression == QUALITY_BINNED (7)");
        }

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "mixed BASE_PACK seq @ read " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "mixed QUALITY_BINNED qual @ read " + i);
            }
        }
    }

    // ── 18. Phase D: cross-language fixture (Python → Java) ────────

    @Test
    void crossLanguageFixtureQualityBinned() throws IOException {
        // Phase D fixture: BASE_PACK on sequences + QUALITY_BINNED on
        // qualities. Qualities buffer is bin centres so the lossy
        // codec round-trip is byte-exact and the cross-language
        // comparison is meaningful.
        byte[] expectedSeq  = pureAcgt();
        byte[] expectedQual = qualBinCentre();
        Path tmp = copyFixtureToTemp("m86_codec_quality_binned.tio");
        try (SpectralDataset ds = SpectralDataset.open(tmp.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "fixture has genomic_0001");
            assertEquals(N_READS, gr.readCount(),
                "fixture read count");
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(expectedSeq, i), r.sequence(),
                    "QB fixture seq @ " + i);
                assertArrayEquals(expectedQualSlice(expectedQual, i),
                    r.qualities(), "QB fixture qual @ " + i);
            }
        } finally {
            try { Files.deleteIfExists(tmp); } catch (IOException ignored) {}
        }
        // Verify channel @compression attributes match the fixture spec.
        Path tmp2 = copyFixtureToTemp("m86_codec_quality_binned.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(tmp2.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset seqDs  = sc.openDataset("sequences");
             Hdf5Dataset qualDs = sc.openDataset("qualities")) {
            assertEquals(Compression.BASE_PACK.ordinal(),
                seqDs.readIntegerAttribute("compression", -1L),
                "fixture sequences @compression == BASE_PACK (6)");
            assertEquals(Compression.QUALITY_BINNED.ordinal(),
                qualDs.readIntegerAttribute("compression", -1L),
                "fixture qualities @compression == QUALITY_BINNED (7)");
        } finally {
            try { Files.deleteIfExists(tmp2); } catch (IOException ignored) {}
        }
    }

    // ── 19. Phase E: round-trip read_names via NAME_TOKENIZED ──────

    @Test
    void roundTripReadNamesNameTokenized(@TempDir Path tmp) {
        // Structured Illumina-style names round-trip byte-exact via
        // NAME_TOKENIZED (lossless codec — M85 Phase B §1).
        List<String> names = illuminaNames(N_READS);
        WrittenGenomicRun run = makeRunWithNames(pureAcgt(), phredCycle(), names,
            Map.of("read_names", Compression.NAME_TOKENIZED));
        Path file = writeRun(tmp, run, "rn-nt.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(N_READS, gr.readCount());
            byte[] seq  = pureAcgt();
            byte[] qual = phredCycle();
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(names.get(i), r.readName(),
                    "NAME_TOKENIZED round-trip @ read " + i);
                // Sequences/qualities (no override) unchanged path.
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "sequences (no override) @ read " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "qualities (no override) @ read " + i);
            }
        }
    }

    // ── 20. Phase E: NAME_TOKENIZED size-win vs M82 compound ───────

    @Test
    void sizeWinNameTokenized(@TempDir Path tmp) {
        // 1000 structured Illumina-style read names. Compares the
        // TOTAL FILE-SIZE delta between the two writes (the HDF5
        // VL_STRING compound stores per-name payloads on the global
        // heap, which Dataset.id.get_storage_size() misses). The
        // Python reference targets ratio < 0.50.
        int n = 1000;
        int len = 100;
        byte[] seq = new byte[n * len];
        byte[] cycle = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < seq.length; i++) seq[i] = cycle[i % 4];
        byte[] qual = new byte[n * len];
        for (int i = 0; i < qual.length; i++) qual[i] = (byte) (30 + (i % 11));
        List<String> names = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            names.add(String.format("INSTR:RUN:1:%d:%d:%d",
                i / 4, i % 4, i * 100));
        }
        WrittenGenomicRun raw = bigRunWithNames(n, len, seq, qual, names, Map.of());
        WrittenGenomicRun nt  = bigRunWithNames(n, len, seq, qual, names,
            Map.of("read_names", Compression.NAME_TOKENIZED));

        Path rawFile = writeRun(tmp, raw, "nt-size-raw.tio");
        Path ntFile  = writeRun(tmp, nt,  "nt-size-nt.tio");

        long rawFileSize, ntFileSize;
        try {
            rawFileSize = Files.size(rawFile);
            ntFileSize  = Files.size(ntFile);
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        long saved = rawFileSize - ntFileSize;

        long ntCodecBytes;
        try (Hdf5File f = Hdf5File.openReadOnly(ntFile.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs = sc.openDataset("read_names")) {
            ntCodecBytes = rnDs.getLength();
        }
        long m82Footprint = ntCodecBytes + saved;
        double ratio = (double) ntCodecBytes / (double) m82Footprint;
        assertTrue(ratio < 0.50,
            "NAME_TOKENIZED read_names dataset = " + ntCodecBytes
            + " bytes; M82 footprint (codec+saved) = " + m82Footprint
            + " bytes; ratio = " + String.format("%.4f", ratio)
            + " (target < 0.50)");
        assertTrue(ntCodecBytes > 0, "NAME_TOKENIZED output non-empty");
    }

    /** bigRun variant accepting custom read names. */
    private static WrittenGenomicRun bigRunWithNames(int n, int len, byte[] seq,
                                                      byte[] qual,
                                                      List<String> names,
                                                      Map<String, Compression> overrides) {
        long[] positions = new long[n];
        for (int i = 0; i < n; i++) positions[i] = i * 1000L;
        byte[] mapqs = new byte[n];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * len;
            lengths[i] = len;
        }
        List<String> cigars = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(len + "M");
            mateChroms.add("chr1");
            chroms.add("chr1");
            matePos[i] = -1L;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "M86_NT_BIG",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, names, mateChroms, matePos, tlens, chroms,
            Compression.NONE, overrides);
    }

    // ── 21. Phase E: @compression == 8 set on read_names dataset ───

    @Test
    void attributeSetCorrectlyNameTokenized(@TempDir Path tmp) {
        // Schema lift: read_names becomes 1-D uint8 (not compound) and
        // carries @compression == 8. Other byte channels are untouched
        // by this override.
        WrittenGenomicRun run = makeRunWithNames(pureAcgt(), phredCycle(),
            illuminaNames(N_READS),
            Map.of("read_names", Compression.NAME_TOKENIZED));
        Path file = writeRun(tmp, run, "rn-nt-attr.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs   = sc.openDataset("read_names");
             Hdf5Dataset seqDs  = sc.openDataset("sequences");
             Hdf5Dataset qualDs = sc.openDataset("qualities")) {
            // Schema-lift dispatch: precision UINT8, not compound.
            assertEquals(global.thalion.ttio.Enums.Precision.UINT8,
                rnDs.getPrecision(),
                "read_names must be 1-D uint8 under NAME_TOKENIZED, "
                + "not compound");
            // @compression carries the codec id.
            assertTrue(rnDs.hasAttribute("compression"),
                "read_names must carry @compression");
            long val = rnDs.readIntegerAttribute("compression", -1L);
            assertEquals(Compression.NAME_TOKENIZED.ordinal(), val,
                "@compression value must be NAME_TOKENIZED ordinal");
            assertEquals(8L, val, "NAME_TOKENIZED is M79 codec id 8");
            // Other channels untouched by this override.
            assertFalse(seqDs.hasAttribute("compression"),
                "sequences must have no @compression attribute");
            assertFalse(qualDs.hasAttribute("compression"),
                "qualities must have no @compression attribute");
        }
    }

    // ── 22. Phase E: back-compat — read_names compound unchanged ───

    @Test
    void backCompatReadNamesUnchanged(@TempDir Path tmp) {
        // No read_names override → read_names stays as M82 compound.
        // Two cases: empty overrides, and overrides on other channels
        // only.
        Map<String, Compression>[] cases = new Map[]{
            Map.of(),
            Map.of("sequences", Compression.BASE_PACK,
                   "qualities", Compression.RANS_ORDER1),
        };
        String[] descs = {"empty", "seq+qual"};
        for (int c = 0; c < cases.length; c++) {
            WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(), cases[c]);
            Path file = writeRun(tmp, run, "backcompat-" + descs[c] + ".tio");
            // Inspect the on-disk shape: read_names must NOT be uint8
            // (it's the M82 compound), and must not carry @compression.
            try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
                 Hdf5Group root = f.rootGroup();
                 Hdf5Group study = root.openGroup("study");
                 Hdf5Group gRuns = study.openGroup("genomic_runs");
                 Hdf5Group rg    = gRuns.openGroup("genomic_0001");
                 Hdf5Group sc    = rg.openGroup("signal_channels");
                 Hdf5Dataset rnDs = sc.openDataset("read_names")) {
                assertNotEquals(global.thalion.ttio.Enums.Precision.UINT8,
                    rnDs.getPrecision(),
                    descs[c] + ": read_names must remain compound, "
                    + "not lifted to uint8");
                assertFalse(rnDs.hasAttribute("compression"),
                    descs[c] + ": M82 compound must not carry @compression");
            }
            // Round-trip via the existing read path.
            try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
                GenomicRun gr = ds.genomicRuns().get("genomic_0001");
                for (int i = 0; i < N_READS; i++) {
                    AlignedRead r = gr.readAt(i);
                    assertEquals("r" + i, r.readName(),
                        descs[c] + ": read " + i + " name");
                }
            }
        }
    }

    // ── 23. Phase E: reject NAME_TOKENIZED on sequences/qualities ──

    @Test
    void rejectNameTokenizedOnSequences(@TempDir Path tmp) {
        // Per Binding Decision §113: NAME_TOKENIZED tokenises UTF-8
        // strings, not binary byte streams. Validation throws
        // IllegalArgumentException at write time; the message must
        // name the codec, the channel, and explain the wrong-input-
        // type rationale. Mentions read_names so the user knows
        // where the codec *does* belong.
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("sequences", Compression.NAME_TOKENIZED));
                writeRun(tmp, bad, "bad-nt-seq.tio");
            });
        String msg = ex.getMessage();
        assertNotNull(msg, "exception must have a message");
        assertTrue(msg.contains("NAME_TOKENIZED"),
            "error must name the codec; got: " + msg);
        assertTrue(msg.contains("sequences"),
            "error must name the channel; got: " + msg);
        assertTrue(msg.contains("tokenises UTF-8"),
            "error must explain that NAME_TOKENIZED tokenises UTF-8; got: " + msg);
        assertTrue(msg.contains("read_names")
                && msg.contains("NAME_TOKENIZED"),
            "error must point at the read_names channel for "
            + "NAME_TOKENIZED; got: " + msg);

        // Same check for the qualities channel (also forbidden).
        IllegalArgumentException exQ = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("qualities", Compression.NAME_TOKENIZED));
                writeRun(tmp, bad, "bad-nt-qual.tio");
            });
        String msgQ = exQ.getMessage();
        assertNotNull(msgQ, "exception must have a message");
        assertTrue(msgQ.contains("NAME_TOKENIZED"),
            "qualities error must name the codec; got: " + msgQ);
        assertTrue(msgQ.contains("qualities"),
            "qualities error must name the channel; got: " + msgQ);
    }

    // ── 24. Phase E: mixed all three overrides ─────────────────────

    @Test
    void mixedAllThreeOverrides(@TempDir Path tmp) {
        // sequences=BASE_PACK + qualities=QUALITY_BINNED + read_names=
        // NAME_TOKENIZED simultaneously. Verifies the on-disk
        // @compression attributes for all three channels and that all
        // three round-trip correctly (with QUALITY_BINNED's bin-centre
        // inputs preserving byte-exact qualities).
        byte[] seq  = pureAcgt();
        byte[] qual = qualBinCentre();
        List<String> names = illuminaNames(N_READS);
        WrittenGenomicRun run = makeRunWithNames(seq, qual, names,
            Map.of("sequences", Compression.BASE_PACK,
                   "qualities", Compression.QUALITY_BINNED,
                   "read_names", Compression.NAME_TOKENIZED));
        Path file = writeRun(tmp, run, "mixed-all-three.tio");

        // Verify all three channels carry their respective codec ids.
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset seqDs  = sc.openDataset("sequences");
             Hdf5Dataset qualDs = sc.openDataset("qualities");
             Hdf5Dataset rnDs   = sc.openDataset("read_names")) {
            assertEquals(Compression.BASE_PACK.ordinal(),
                seqDs.readIntegerAttribute("compression", -1L),
                "sequences @compression == BASE_PACK (6)");
            assertEquals(Compression.QUALITY_BINNED.ordinal(),
                qualDs.readIntegerAttribute("compression", -1L),
                "qualities @compression == QUALITY_BINNED (7)");
            assertEquals(Compression.NAME_TOKENIZED.ordinal(),
                rnDs.readIntegerAttribute("compression", -1L),
                "read_names @compression == NAME_TOKENIZED (8)");
            // read_names must be the lifted 1-D uint8 layout.
            assertEquals(global.thalion.ttio.Enums.Precision.UINT8,
                rnDs.getPrecision(),
                "read_names must be 1-D uint8 under NAME_TOKENIZED");
        }

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(N_READS, gr.readCount());
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedSeqSlice(seq, i), r.sequence(),
                    "mixed BASE_PACK seq @ read " + i);
                assertArrayEquals(expectedQualSlice(qual, i), r.qualities(),
                    "mixed QUALITY_BINNED qual @ read " + i);
                assertEquals(names.get(i), r.readName(),
                    "mixed NAME_TOKENIZED read_name @ read " + i);
            }
        }
    }

    // ── 25. Phase E: cross-language fixture (Python → Java) ────────

    @Test
    void crossLanguageFixtureNameTokenized() throws IOException {
        // Phase E fixture: NAME_TOKENIZED on read_names with structured
        // Illumina-style names. Sequences/qualities use the default
        // (non-codec) HDF5 path on the Python side too, so we only
        // assert the read_name round-trip matches the deterministic
        // generator.
        List<String> expectedNames = illuminaNames(N_READS);
        Path tmp = copyFixtureToTemp("m86_codec_name_tokenized.tio");
        try (SpectralDataset ds = SpectralDataset.open(tmp.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "fixture has genomic_0001");
            assertEquals(N_READS, gr.readCount(), "fixture read count");
            for (int i = 0; i < N_READS; i++) {
                AlignedRead r = gr.readAt(i);
                assertEquals(expectedNames.get(i), r.readName(),
                    "NAME_TOKENIZED fixture read_name @ " + i);
            }
        } finally {
            try { Files.deleteIfExists(tmp); } catch (IOException ignored) {}
        }
        // Verify the on-disk schema-lift layout (uint8 + @compression == 8).
        Path tmp2 = copyFixtureToTemp("m86_codec_name_tokenized.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(tmp2.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs = sc.openDataset("read_names")) {
            assertEquals(global.thalion.ttio.Enums.Precision.UINT8,
                rnDs.getPrecision(),
                "fixture read_names must be 1-D uint8 (schema-lifted)");
            assertEquals(Compression.NAME_TOKENIZED.ordinal(),
                rnDs.readIntegerAttribute("compression", -1L),
                "fixture read_names @compression == NAME_TOKENIZED (8)");
        } finally {
            try { Files.deleteIfExists(tmp2); } catch (IOException ignored) {}
        }
    }
}
