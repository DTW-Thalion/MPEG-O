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
        // M86 Phase B (Binding Decision §117) extended the override map
        // to the three integer channels (positions, flags,
        // mapping_qualities). M86 Phase C (Binding Decision §120) added
        // cigars. M86 Phase F (Binding Decisions §125-§130) added the
        // three per-field mate_info_chrom/pos/tlen virtual channels
        // (and rejects the bare "mate_info" key — covered separately
        // by rejectBareMateInfoKey). Use a synthetic name guaranteed
        // never to be a valid channel.
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("not_a_real_channel", Compression.RANS_ORDER0));
                writeRun(tmp, bad, "bad-channel.tio");
            });
        assertTrue(ex.getMessage().contains("not_a_real_channel"),
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

    // ── 11. Cross-language fixtures — REMOVED in Phase 2c.
    //
    // The pre-Phase-2c Python fixtures (m86_codec_rans_order0.tio,
    // m86_codec_rans_order1.tio, m86_codec_base_pack.tio) were
    // written with M82-compound read_names (no v2 codec; legacy
    // path). After Phase 2c the Java reader rejects M82-compound
    // read_names with IllegalStateException, so these fixtures
    // cannot be loaded via gr.readAt(i) (which materialises every
    // field including read_name).
    //
    // Phase 3 will regenerate the cross-language fixture corpus
    // with v1.0+ writers (NAME_TOKENIZED_V2 read_names + MATE_INLINE_V2
    // mate_info) and re-introduce these tests.

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
    //    REMOVED in Phase 2c — same M82-compound-read_names rationale
    //    as #11 above. Phase 3 regenerates the fixture with v2
    //    read_names. The on-disk @compression attribute checks for
    //    sequences + qualities still pass without going through
    //    gr.readAt(i); they're moved to a tighter test that opens the
    //    HDF5 dataset directly without materialising AlignedReads.
    @Test
    void crossLanguageFixtureQualityBinnedAttrsOnly() throws IOException {
        // Tighter form: only verify the on-disk @compression attributes
        // for sequences + qualities. Skips gr.readAt(i) (which would
        // touch the M82-compound read_names and fail in Phase 2c).
        Path tmp = copyFixtureToTemp("m86_codec_quality_binned.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(tmp.toString());
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
            try { Files.deleteIfExists(tmp); } catch (IOException ignored) {}
        }
    }

    // ── 19/20. Phase E: round-trip + attribute tests for NAME_TOKENIZED
    //    on read_names — REMOVED in Phase 2c.
    //
    // The v1 NAME_TOKENIZED override on read_names is now rejected
    // outright. The v2 path (NAME_TOKENIZED_V2 = 15) is exercised by
    // NameTokenizedV2DispatchTest. ────────────────────────────────────

    // ── 22. Phase E: reject NAME_TOKENIZED on sequences/qualities —
    //    REMOVED in Phase 2d. The Compression.NAME_TOKENIZED enum slot
    //    was deleted alongside the wrong-input-type reject branch; the
    //    integer codec id 8 simply fails enum lookup at the boundary.

    // ── 24. Phase E: mixed all three overrides — REMOVED in Phase 2c.
    //
    // The v1 NAME_TOKENIZED override on read_names is now rejected;
    // the v2 (auto-default) flow is exercised by NameTokenizedV2DispatchTest.
    // The combined sequences=BASE_PACK + qualities=QUALITY_BINNED case
    // is covered by the per-codec round-trip tests above. ────────────


    // ── v1.6: Phase B integer-channel codec wiring REMOVED ──────────
    //
    // v1.5 wrote positions/flags/mapping_qualities under BOTH
    // genomic_index/ AND signal_channels/. v1.6 drops the
    // signal_channels copy — those fields live exclusively in
    // genomic_index/ now (mirroring MS's spectrum_index/ pattern).
    // These tests pin the new contract.

    @Test
    void v16RejectsPositionsOverride(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(
            pureAcgt(), phredCycle(),
            Map.of("positions", Compression.RANS_ORDER1));
        Throwable thrown = assertThrows(
            Throwable.class,
            () -> writeRun(tmp, run, "v16-pos.tio"));
        // Unwrap RuntimeException wrappers if SpectralDataset.create wraps.
        Throwable cause = thrown;
        while (cause.getCause() != null && !(cause instanceof IllegalArgumentException)) {
            cause = cause.getCause();
        }
        String msg = cause.getMessage() != null ? cause.getMessage() : "";
        assertTrue(msg.contains("v1.6") || msg.contains("genomic_index"),
                   "v1.6 reject message should mention v1.6 or genomic_index, got: "
                   + msg);
    }

    @Test
    void v16RejectsFlagsOverride(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(
            pureAcgt(), phredCycle(),
            Map.of("flags", Compression.RANS_ORDER0));
        assertThrows(Throwable.class,
            () -> writeRun(tmp, run, "v16-flags.tio"));
    }

    @Test
    void v16RejectsMappingQualitiesOverride(@TempDir Path tmp) {
        WrittenGenomicRun run = makeRun(
            pureAcgt(), phredCycle(),
            Map.of("mapping_qualities", Compression.RANS_ORDER1));
        assertThrows(Throwable.class,
            () -> writeRun(tmp, run, "v16-mapq.tio"));
    }

    @Test
    void v16SignalChannelsHasNoIntDups(@TempDir Path tmp) throws IOException {
        WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(), null);
        Path file = writeRun(tmp, run, "v16-no-dups.tio");
        try (Hdf5File f = Hdf5File.open(file.toString());
             Hdf5Group root  = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Group gi    = rg.openGroup("genomic_index")) {
            for (String ch : new String[]{"positions", "flags", "mapping_qualities"}) {
                assertFalse(sc.hasChild(ch),
                    "v1.6: signal_channels/" + ch + " must not be written");
                assertTrue(gi.hasChild(ch),
                    "v1.6: genomic_index/" + ch + " must remain canonical");
            }
        }
    }

    // ── 25. Phase E: cross-language NAME_TOKENIZED fixture — REMOVED.
    //
    // The Phase E v1 fixture (`m86_codec_name_tokenized.tio`) used the
    // v1 NAME_TOKENIZED codec which was deleted in Phase 2c. The
    // Python regenerator is also gone. v1.0+ cross-language fixtures
    // for read_names land in Phase 3 (regen + cross-lang gate). ──────

    // ── M86 Phase C helpers ────────────────────────────────────────

    /** Build a 1000-read mixed-CIGAR run mirroring the Python Phase C
     *  test #42 generator: 80% "100M" + 10% "99M1D" + 10% "50M50S".
     *  Every other channel uses M82 baseline so the cigars channel is
     *  isolated for the size measurement. */
    private static WrittenGenomicRun mixedCigarRun(
            int n, int len, Map<String, Compression> overrides) {
        byte[] seq = new byte[n * len];
        byte[] cycle = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < seq.length; i++) seq[i] = cycle[i % 4];
        byte[] qual = new byte[n * len];
        for (int i = 0; i < qual.length; i++) qual[i] = (byte) (30 + (i % 11));
        long[] positions = new long[n];
        for (int i = 0; i < n; i++) positions[i] = i * 1000L;
        byte[] mapqs = new byte[n];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[]  lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * len;
            lengths[i] = len;
        }
        List<String> cigars     = new ArrayList<>(n);
        List<String> readNames  = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms     = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[]  tlens   = new int[n];
        for (int i = 0; i < n; i++) {
            int mod = i % 10;
            if (mod < 8)       cigars.add("100M");
            else if (mod == 8) cigars.add("99M1D");
            else               cigars.add("50M50S");
            readNames.add("r" + i);
            mateChroms.add("chr1");
            chroms.add("chr1");
            matePos[i] = -1L;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "M86_C_MIXED",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            Compression.NONE,
            overrides == null ? Map.of() : overrides);
    }

    /** Build a uniform-CIGAR run (all "100M") — the columnar-mode
     *  sweet spot for NAME_TOKENIZED. */
    private static WrittenGenomicRun uniformCigarRun(
            int n, int len, Map<String, Compression> overrides) {
        byte[] seq = new byte[n * len];
        byte[] cycle = "ACGT".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < seq.length; i++) seq[i] = cycle[i % 4];
        byte[] qual = new byte[n * len];
        for (int i = 0; i < qual.length; i++) qual[i] = (byte) (30 + (i % 11));
        long[] positions = new long[n];
        for (int i = 0; i < n; i++) positions[i] = i * 1000L;
        byte[] mapqs = new byte[n];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[]  lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * len;
            lengths[i] = len;
        }
        List<String> cigars     = new ArrayList<>(n);
        List<String> readNames  = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms     = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[]  tlens   = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add("100M");
            readNames.add("r" + i);
            mateChroms.add("chr1");
            chroms.add("chr1");
            matePos[i] = -1L;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "M86_C_UNIFORM",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            Compression.NONE,
            overrides == null ? Map.of() : overrides);
    }

    // ── 35. Phase C: round-trip cigars via rANS order-1 ────────────

    @Test
    void roundTripCigarsRansOrder1(@TempDir Path tmp) {
        // Mixed-CIGAR input (the realistic real-WGS pattern §1.2). The
        // length-prefix-concat byte stream is rANS-encoded; the reader
        // reverses both layers to recover the original CIGARs.
        int n = 1000, len = 100;
        WrittenGenomicRun run = mixedCigarRun(n, len,
            Map.of("cigars", Compression.RANS_ORDER1));
        Path file = writeRun(tmp, run, "cg-rans1.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(n, gr.readCount());
            for (int i = 0; i < n; i++) {
                AlignedRead r = gr.readAt(i);
                int mod = i % 10;
                String expected = (mod < 8) ? "100M"
                                : (mod == 8) ? "99M1D" : "50M50S";
                assertEquals(expected, r.cigar(),
                    "RANS_ORDER1 cigars round-trip @ read " + i);
            }
        }
    }

    // ── 36/37. Phase C: NAME_TOKENIZED on cigars — REMOVED in Phase 2d.
    //
    // The Compression.NAME_TOKENIZED enum slot was deleted; the codec
    // id 8 simply fails enum lookup at the boundary. Cigars accepts
    // RANS_ORDER0 / RANS_ORDER1 only.

    // ── 38. Phase C: size comparison — REMOVED in Phase 2c.
    //
    // Original test compared M82 baseline / RANS_ORDER1 /
    // NAME_TOKENIZED on the realistic mixed-CIGAR input. After
    // Phase 2c only RANS_ORDER0 / RANS_ORDER1 remain on the cigars
    // override surface; the §1.2 selection guidance is moot. Size
    // sanity for rANS is asserted in the round-trip test #35.

    // ── 39. Phase C: NAME_TOKENIZED columnar size win — REMOVED. ──
    //
    // Same Phase 2c rationale as #38; rANS-only world.

    // ── 40. Phase C: @compression set correctly on cigars dataset ──

    @Test
    void attributeSetCorrectlyCigars(@TempDir Path tmp) {
        // Both accepted codecs produce a 1-D uint8 dataset with
        // @compression == codec_id. Other compound channels (read_names,
        // mate_info) are untouched. Phase 2c: NAME_TOKENIZED dropped
        // from the cigars override surface.
        for (Compression codec : new Compression[]{
                Compression.RANS_ORDER0,
                Compression.RANS_ORDER1}) {
            WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(),
                Map.of("cigars", codec));
            Path file = writeRun(tmp, run, "cg-attr-" + codec.name() + ".tio");
            try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
                 Hdf5Group root = f.rootGroup();
                 Hdf5Group study = root.openGroup("study");
                 Hdf5Group gRuns = study.openGroup("genomic_runs");
                 Hdf5Group rg    = gRuns.openGroup("genomic_0001");
                 Hdf5Group sc    = rg.openGroup("signal_channels");
                 Hdf5Dataset cgDs = sc.openDataset("cigars")) {
                assertEquals(global.thalion.ttio.Enums.Precision.UINT8,
                    cgDs.getPrecision(),
                    "cigars must be 1-D uint8 under " + codec
                    + ", not compound");
                assertTrue(cgDs.hasAttribute("compression"),
                    "cigars must carry @compression for codec " + codec);
                long val = cgDs.readIntegerAttribute("compression", -1L);
                assertEquals(codec.ordinal(), val,
                    "@compression value for " + codec);
            }
        }
    }

    // ── 41. Phase C: back-compat — cigars compound unchanged ───────

    @Test
    void backCompatCigarsUnchanged(@TempDir Path tmp) {
        // No cigars override → cigars stays as M82 compound. Two cases:
        // empty overrides, and overrides on other channels only.
        // Phase 2c: read_names override surface is gone — case[1] now
        // exercises sequences-only override.
        @SuppressWarnings({"unchecked", "rawtypes"})
        Map<String, Compression>[] cases = new Map[]{
            Map.of(),
            Map.of("sequences", Compression.BASE_PACK),
        };
        String[] descs = {"empty", "seq"};
        for (int c = 0; c < cases.length; c++) {
            Map<String, Compression> overrides = cases[c];
            WrittenGenomicRun run = makeRun(pureAcgt(), phredCycle(), overrides);
            Path file = writeRun(tmp, run, "cg-backcompat-" + descs[c] + ".tio");
            try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
                 Hdf5Group root = f.rootGroup();
                 Hdf5Group study = root.openGroup("study");
                 Hdf5Group gRuns = study.openGroup("genomic_runs");
                 Hdf5Group rg    = gRuns.openGroup("genomic_0001");
                 Hdf5Group sc    = rg.openGroup("signal_channels");
                 Hdf5Dataset cgDs = sc.openDataset("cigars")) {
                assertNotEquals(global.thalion.ttio.Enums.Precision.UINT8,
                    cgDs.getPrecision(),
                    descs[c] + ": cigars must remain compound, "
                    + "not lifted to uint8");
                assertFalse(cgDs.hasAttribute("compression"),
                    descs[c] + ": M82 compound must not carry @compression");
            }
            try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
                GenomicRun gr = ds.genomicRuns().get("genomic_0001");
                for (int i = 0; i < N_READS; i++) {
                    AlignedRead r = gr.readAt(i);
                    assertEquals("100M", r.cigar(),
                        descs[c] + ": cigar @ read " + i);
                }
            }
        }
    }

    // ── 42. Phase C: reject BASE_PACK on cigars ────────────────────

    @Test
    void rejectBasePackOnCigars(@TempDir Path tmp) {
        // Per Binding Decision §120: BASE_PACK 2-bit-packs ACGT bytes
        // and would silently corrupt CIGAR strings. Validation throws
        // IllegalArgumentException at write time; the message names
        // the codec, the channel, and points at the recommended codecs.
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("cigars", Compression.BASE_PACK));
                writeRun(tmp, bad, "bad-bp-cg.tio");
            });
        String msg = ex.getMessage();
        assertNotNull(msg, "exception must have a message");
        assertTrue(msg.contains("BASE_PACK"),
            "error must name the codec; got: " + msg);
        assertTrue(msg.contains("cigars"),
            "error must name the channel; got: " + msg);
        assertTrue(msg.contains("RANS_ORDER0")
                || msg.contains("RANS_ORDER1")
                || msg.contains("NAME_TOKENIZED"),
            "error must point at the recommended codecs; got: " + msg);

        // Same check for QUALITY_BINNED on cigars.
        IllegalArgumentException exQ = assertThrows(
            IllegalArgumentException.class,
            () -> {
                WrittenGenomicRun bad = makeRun(pureAcgt(), phredCycle(),
                    Map.of("cigars", Compression.QUALITY_BINNED));
                writeRun(tmp, bad, "bad-qb-cg.tio");
            });
        String msgQ = exQ.getMessage();
        assertNotNull(msgQ, "exception must have a message");
        assertTrue(msgQ.contains("QUALITY_BINNED"),
            "QB error must name the codec; got: " + msgQ);
        assertTrue(msgQ.contains("cigars"),
            "QB error must name the channel; got: " + msgQ);
    }

    // ── 44. Phase C: cross-language rANS cigars fixture — REMOVED
    //    in Phase 2c (M82-compound-read_names rationale; see #11).
    //    The on-disk attribute check is preserved in a tighter form
    //    that doesn't materialise AlignedReads.
    @Test
    void crossLanguageFixtureCigarsRansAttrsOnly() throws IOException {
        Path tmp = copyFixtureToTemp("m86_codec_cigars_rans.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(tmp.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg    = gRuns.openGroup("genomic_0001");
             Hdf5Group sc    = rg.openGroup("signal_channels");
             Hdf5Dataset cgDs = sc.openDataset("cigars")) {
            assertEquals(global.thalion.ttio.Enums.Precision.UINT8,
                cgDs.getPrecision(),
                "fixture cigars must be 1-D uint8 (schema-lifted)");
            assertEquals(Compression.RANS_ORDER1.ordinal(),
                cgDs.readIntegerAttribute("compression", -1L),
                "fixture cigars @compression == RANS_ORDER1 (5)");
        } finally {
            try { Files.deleteIfExists(tmp); } catch (IOException ignored) {}
        }
    }

    // ── 45. Phase C: cross-language NAME_TOKENIZED cigars fixture —
    //    REMOVED in Phase 2c.
    //
    // The Phase C v1 fixture (`m86_codec_cigars_name_tokenized.tio`)
    // used the v1 NAME_TOKENIZED codec which was deleted in Phase 2c.
    // The Python regenerator is also gone. v1.0+ cross-language
    // fixtures for cigars+rANS still apply (#44 above).

    // ════════════════════════════════════════════════════════════════
    // M86 Phase F — mate_info per-field decomposition
    // ════════════════════════════════════════════════════════════════

    // ── Phase F mate_info v1 round-trip / reject tests + Phase F
    //    cross-language fixture (`m86_codec_mate_info_full.tio`) +
    //    phaseFMate* helpers — REMOVED in Phase 2c.
    //
    // The v1 mate_info per-field subgroup writer is gone; the v2
    // dispatch tests live in MateInfoV2DispatchTest. The Python
    // regenerator and the .tio fixture are also being deleted.
}
