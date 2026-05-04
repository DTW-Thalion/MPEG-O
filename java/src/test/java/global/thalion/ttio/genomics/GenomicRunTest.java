/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import java.util.LinkedHashMap;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M82.3 acceptance tests for the genomic data model.
 *
 * <p>Mirrors the Python M82.1 acceptance suite + ObjC M82.2
 * {@code TestM82GenomicRun.m}. Cross-language fixture read at the
 * tail validates that a Java reader opens a Python-written
 * {@code m82_100reads.tio} with field-level equivalence.</p>
 */
class GenomicRunTest {

    // ── Helper: synthetic genomic run (matches Python _make_written_run) ─

    private static WrittenGenomicRun makeRun(int nReads, boolean paired) {
        int readLength = 150;
        String[] chromsPool = {"chr1", "chr2", "chrX"};

        List<String> chroms = new ArrayList<>(nReads);
        long[] positions = new long[nReads];
        int[] flags = new int[nReads];
        byte[] mapqs = new byte[nReads];
        for (int i = 0; i < nReads; i++) {
            chroms.add(chromsPool[i % 3]);
            positions[i] = 10000L + (i / 3) * 100L;
            mapqs[i] = 60;
            flags[i] = paired ? 0x1 : 0;
        }

        byte[] sequences = new byte[nReads * readLength];
        char[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = (byte) bases[i % 4];
        }
        byte[] qualities = new byte[nReads * readLength];
        java.util.Arrays.fill(qualities, (byte) 30);

        long[] offsets = new long[nReads];
        int[] lengths = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            offsets[i] = (long) i * readLength;
            lengths[i] = readLength;
        }

        List<String> cigars = new ArrayList<>(nReads);
        List<String> readNames = new ArrayList<>(nReads);
        List<String> mateChroms = new ArrayList<>(nReads);
        long[] matePos = new long[nReads];
        int[] tlens = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            cigars.add(readLength + "M");
            readNames.add(String.format("read_%06d", i));
            mateChroms.add(paired ? chroms.get(i) : "");
            matePos[i] = paired ? positions[i] + 200L : -1L;
            tlens[i] = paired ? 200 : 0;
        }

        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mapqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chroms, Compression.ZLIB);
    }

    // ── AlignedRead value-class tests ──────────────────────────────

    @Test
    void alignedReadConstructionAndAccessors() {
        AlignedRead r = new AlignedRead(
            "read_001", "chr1", 12345L, 60, "150M",
            "AAAAAA", "IIIIII".getBytes(), 0,
            "", -1L, 0);
        assertEquals("read_001", r.readName());
        assertEquals("chr1", r.chromosome());
        assertEquals(12345L, r.position());
        assertEquals(60, r.mappingQuality());
        assertEquals("150M", r.cigar());
        assertEquals(6, r.readLength());
        assertEquals(0, r.flags());
        assertEquals(-1L, r.matePosition());
        assertEquals(0, r.templateLength());
    }

    @Test
    void alignedReadFlagAccessors() {
        java.util.function.IntFunction<AlignedRead> mk = (flags) ->
            new AlignedRead("r", "chr1", 0L, 0, "0M", "", new byte[0],
                flags, "", -1L, 0);
        assertTrue(mk.apply(0).isMapped());
        assertFalse(mk.apply(0x4).isMapped());
        assertFalse(mk.apply(0).isPaired());
        assertTrue(mk.apply(0x1).isPaired());
        assertFalse(mk.apply(0).isReverse());
        assertTrue(mk.apply(0x10).isReverse());
        assertFalse(mk.apply(0).isSecondary());
        assertTrue(mk.apply(0x100).isSecondary());
        assertFalse(mk.apply(0).isSupplementary());
        assertTrue(mk.apply(0x800).isSupplementary());
    }

    // ── GenomicIndex in-memory tests ───────────────────────────────

    private static GenomicIndex makeIndex6() {
        long[] offsets    = {0, 150, 300, 450, 600, 750};
        int[]  lengths    = {150, 150, 150, 150, 150, 150};
        long[] positions  = {100, 15000, 100, 200, 100, 25000};
        byte[] mapqs      = {60, 60, 0, 60, 60, 60};
        int[]  flags      = {0, 0, 0x4, 0x10, 0x1, 0};
        List<String> chroms = List.of("chr1", "chr1", "chr2", "chr2", "chrX", "chr1");
        return new GenomicIndex(offsets, lengths, chroms, positions, mapqs, flags);
    }

    @Test
    void genomicIndexInMemoryQueries() {
        GenomicIndex idx = makeIndex6();
        assertEquals(6, idx.count());
        assertEquals(0L, idx.offsetAt(0));
        assertEquals(150, idx.lengthAt(5));
        assertEquals(15000L, idx.positionAt(1));
        assertEquals(0, idx.mappingQualityAt(2));
        assertEquals(0x10, idx.flagsAt(3));
        assertEquals("chrX", idx.chromosomeAt(4));

        List<Integer> region = idx.indicesForRegion("chr1", 10000, 20000);
        assertEquals(List.of(1), region);
        assertTrue(idx.indicesForRegion("chrY", 0, 1_000_000).isEmpty());

        assertEquals(List.of(2), idx.indicesForUnmapped());
        assertEquals(List.of(3), idx.indicesForFlag(0x10));
        assertEquals(List.of(4), idx.indicesForFlag(0x1));
    }

    // ── Acceptance #1 — 100-read round-trip via HDF5 ─────────────

    @Test
    void basicRoundTrip100Reads(@TempDir Path tmp) {
        Path file = tmp.resolve("m82.tio");
        WrittenGenomicRun written = makeRun(100, false);

        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(written),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertEquals(1, ds.genomicRuns().size());
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            assertEquals(100, gr.readCount());
            assertEquals("GRCh38.p14", gr.referenceUri());
            assertEquals(AcquisitionMode.GENOMIC_WGS, gr.acquisitionMode());

            AlignedRead r0 = gr.readAt(0);
            assertEquals("read_000000", r0.readName());
            assertEquals("chr1", r0.chromosome());
            assertEquals(10000L, r0.position());
            assertEquals("150M", r0.cigar());
            assertEquals(150, r0.sequence().length());
            assertEquals(0, r0.flags());
            // v1.7 mate_info v2 normalizes "" / "*" inputs to "*" on read
            // (id=-1 sentinel; SpectralDataset.writeMateInfoV2 normalizes,
            // GenomicRun.mateChromAt decodes id=-1 → "*").
            assertEquals("*", r0.mateChromosome());
            assertEquals(-1L, r0.matePosition());

            AlignedRead r99 = gr.readAt(99);
            assertEquals("read_000099", r99.readName());
        }
    }

    // ── Acceptance #2 — region query ───────────────────────────────

    @Test
    void regionQuery(@TempDir Path tmp) {
        Path file = tmp.resolve("m82rq.tio");
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(makeRun(100, false)),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            List<AlignedRead> hits = gr.readsInRegion("chr1", 10000, 10500);
            assertFalse(hits.isEmpty());
            for (AlignedRead r : hits) {
                assertEquals("chr1", r.chromosome());
                assertTrue(r.position() >= 10000 && r.position() < 10500);
            }
            assertTrue(gr.readsInRegion("chrY", 0, 1_000_000).isEmpty());
        }
    }

    // ── Acceptance #3 — flag filter ────────────────────────────────

    @Test
    void flagFilter(@TempDir Path tmp) {
        Path file = tmp.resolve("m82ff.tio");
        WrittenGenomicRun base = makeRun(100, false);
        // Patch flags: read 7 unmapped, reads 3+9 reverse-strand.
        int[] flags = base.flags().clone();
        flags[7] |= 0x4;
        flags[3] |= 0x10;
        flags[9] |= 0x10;
        WrittenGenomicRun patched = new WrittenGenomicRun(
            base.acquisitionMode(), base.referenceUri(), base.platform(),
            base.sampleName(), base.positions(), base.mappingQualities(),
            flags, base.sequences(), base.qualities(),
            base.offsets(), base.lengths(),
            base.cigars(), base.readNames(), base.mateChromosomes(),
            base.matePositions(), base.templateLengths(),
            base.chromosomes(), base.signalCompression());

        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(patched),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(List.of(7), gr.index().indicesForUnmapped());
            assertEquals(List.of(3, 9), gr.index().indicesForFlag(0x10));
        }
    }

    // ── Acceptance #4 — paired-end mate info ───────────────────────

    @Test
    void pairedEndMateInfo(@TempDir Path tmp) {
        Path file = tmp.resolve("m82pe.tio");
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(makeRun(100, true)),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            AlignedRead r0 = gr.readAt(0);
            assertTrue(r0.isPaired());
            assertEquals("chr1", r0.mateChromosome());
            assertEquals(10200L, r0.matePosition());
            assertEquals(200, r0.templateLength());
        }
    }

    // ── Acceptance #5 — multi-omics file ───────────────────────────

    @Test
    void multiOmicsFile(@TempDir Path tmp) {
        Path file = tmp.resolve("m82mo.tio");
        // Minimal MS run with 3 spectra of 3 peaks each.
        int specCount = 3, peaksPerSpec = 3;
        int total = specCount * peaksPerSpec;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        long[] msOffsets = new long[specCount];
        int[] msLengths = new int[specCount];
        double[] rts = new double[specCount];
        int[] msLevels = new int[specCount];
        int[] pols = new int[specCount];
        double[] pmzs = new double[specCount];
        int[] pcs = new int[specCount];
        double[] bpis = new double[specCount];
        for (int i = 0; i < specCount; i++) {
            msOffsets[i] = (long) i * peaksPerSpec;
            msLengths[i] = peaksPerSpec;
            rts[i] = i * 0.5;
            msLevels[i] = 1;
            pols[i] = 1;
            for (int j = 0; j < peaksPerSpec; j++) {
                int k = i * peaksPerSpec + j;
                mz[k] = 100.0 + j * 10.0 + i * 0.1;
                intensity[k] = 1000.0 * (j + 1) + i;
            }
            bpis[i] = 1000.0 * peaksPerSpec + i;
        }
        SpectrumIndex msIdx = new SpectrumIndex(specCount, msOffsets, msLengths,
            rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> chans = new LinkedHashMap<>();
        chans.put("mz", mz);
        chans.put("intensity", intensity);
        AcquisitionRun msRun = new AcquisitionRun("run_0001",
            AcquisitionMode.MS1_DDA, msIdx,
            new InstrumentConfig("", "", "", "", "", ""),
            chans, List.of(), List.of(), null, 0);

        SpectralDataset.create(file.toString(), "t", "i",
            List.of(msRun), List.of(makeRun(100, false)),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertNotNull(ds.msRuns().get("run_0001"));
            assertEquals(100, ds.genomicRuns().get("genomic_0001").readCount());
        }
    }

    // ── Acceptance #6 — empty run ─────────────────────────────────

    @Test
    void emptyRun(@TempDir Path tmp) {
        Path file = tmp.resolve("m82er.tio");
        WrittenGenomicRun empty = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "NA12878",
            new long[0], new byte[0], new int[0], new byte[0], new byte[0],
            new long[0], new int[0], List.of(), List.of(), List.of(),
            new long[0], new int[0], List.of(), Compression.ZLIB);

        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(empty),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            assertEquals(0, gr.readCount());
        }
    }

    // ── Acceptance #7 — Memory provider round-trip ────────────────

    @Test
    void memoryProviderRoundTrip() {
        String url = "memory://m82-test-" + System.nanoTime();
        SpectralDataset.create(url, "t", "i",
            List.of(), List.of(makeRun(100, false)),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(url)) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(100, gr.readCount());
            AlignedRead r42 = gr.readAt(42);
            assertEquals("read_000042", r42.readName());
        }
    }

    // ── Acceptance #8 — pre-M82 backward compat ───────────────────

    @Test
    void preM82BackwardCompat(@TempDir Path tmp) {
        Path file = tmp.resolve("m82bc.tio");
        // Write MS-only file via the legacy 7-arg create (no genomic_runs).
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertTrue(ds.genomicRuns().isEmpty(),
                "pre-M82 file should have empty genomicRuns map");
        }
    }

    // ── Random-access read on a 1000-read run ─────────────────────

    @Test
    void randomAccessRead(@TempDir Path tmp) {
        Path file = tmp.resolve("m82ra.tio");
        SpectralDataset.create(file.toString(), "t", "i",
            List.of(), List.of(makeRun(1000, false)),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertEquals(1000, gr.readCount());
            AlignedRead r500 = gr.readAt(500);
            assertEquals("read_000500", r500.readName());
            assertEquals(150, r500.sequence().length());
        }
    }

    // ── Cross-language fixture read (Python → Java, full) ─────────
    //
    // M82.4: Java reads VL_STRING fields out of compound datasets via
    // Hdf5CompoundIO.readCompoundFull which dereferences the char*
    // pointers in the H5Dread buffer using sun.misc.Unsafe. Same
    // on-disk wire format as Python and ObjC; no JHI5 upgrade needed.

    @Test
    void crossLanguageFixtureRead() {
        Path fixture = Path.of(System.getProperty("user.home"),
            "TTI-O", "python", "tests", "fixtures", "genomic", "m82_100reads.tio");
        if (!java.nio.file.Files.exists(fixture)) {
            System.out.println("SKIP: cross-language fixture not found at " + fixture);
            return;
        }

        try (SpectralDataset ds = SpectralDataset.open(fixture.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "Python-written fixture should have genomic_0001");
            assertEquals(100, gr.readCount(), "100 reads from Python");
            assertEquals("GRCh38.p14", gr.referenceUri());
            assertEquals("ILLUMINA", gr.platform());
            assertEquals("NA12878", gr.sampleName());
            assertEquals(AcquisitionMode.GENOMIC_WGS, gr.acquisitionMode());

            AlignedRead first = gr.readAt(0);
            assertNotNull(first);
            assertEquals(150, first.sequence().length());
            assertEquals(150, first.qualities().length);
            assertEquals("150M", first.cigar(), "M82.4: cigar via VL_STRING");
            assertEquals("read_000000", first.readName(),
                "M82.4: read_name via VL_STRING");
            // Python's _make_written_run assigns chromosomes round-robin
            // across {chr1, chr2, chrX}; read 0 lands on chr1.
            assertEquals("chr1", first.chromosome(),
                "M82.4: chromosome via VL_STRING (in genomic_index)");
        }
    }
}
