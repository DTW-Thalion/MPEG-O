/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage for the {@link RunSelection} branches not exercised by
 * {@link RunSelectionTest}: {@link RunSelection#genomicRun},
 * {@link RunSelection#nmrRun}, and {@link RunSelection#toWritten}.
 *
 * <p>Each test builds a real {@code .tio}, reopens it, runs the selection
 * helper, and asserts the picked run / round-tripped fields, so the
 * conversion logic (not just line reachability) is validated.</p>
 */
class RunSelectionGenomicNmrTest {

    @TempDir
    Path tmp;

    // ── Fixtures ────────────────────────────────────────────────────

    private static SpectrumIndex oneSpectrum(int n) {
        return new SpectrumIndex(1,
            new long[]{0}, new int[]{n},
            new double[]{0.0}, new int[]{0}, new int[]{0},
            new double[]{0.0}, new int[]{0}, new double[]{1.0});
    }

    private static AcquisitionRun msRun(String name) {
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100, 200});
        ch.put("intensity", new double[]{1, 2});
        return new AcquisitionRun(name, AcquisitionMode.MS1_DDA,
            oneSpectrum(2), null, ch, List.of(), List.of(), null, 0);
    }

    private static AcquisitionRun nmrRun(String name) {
        int n = 16;
        double[] cs = new double[n];
        double[] in = new double[n];
        for (int i = 0; i < n; i++) {
            cs[i] = i * 0.1;
            in[i] = 100.0;
        }
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("chemical_shift", cs);
        ch.put("intensity", in);
        return new AcquisitionRun(name, AcquisitionMode.NMR_1D,
            oneSpectrum(n),
            new InstrumentConfig("v", "m", "sn", "RF", "FT", "RF"),
            ch, List.of(), List.of(), "1H", 400.0);
    }

    private static WrittenGenomicRun makeGenomic(String ref, String platform,
                                                 String sample) {
        int n = 3;
        int rl = 8;
        long[] positions = {100L, 110L, 120L};
        int[] flags = {0, 0x10, 0};
        byte[] mapqs = {60, 55, 60};
        List<String> chroms = new ArrayList<>(List.of("chr1", "chr2", "chr1"));
        byte[] seq = new byte[n * rl];
        char[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < seq.length; i++) seq[i] = (byte) bases[i % 4];
        byte[] quals = new byte[n * rl];
        Arrays.fill(quals, (byte) 35);
        long[] offsets = {0, rl, 2L * rl};
        int[] lengths = {rl, rl, rl};
        List<String> cigars = new ArrayList<>(List.of("8M", "8M", "8M"));
        List<String> readNames = new ArrayList<>(
            List.of("r0", "r1", "r2"));
        List<String> mateChroms = new ArrayList<>(List.of("", "", ""));
        long[] matePos = {-1L, -1L, -1L};
        int[] tlens = {0, 0, 0};
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, ref, platform, sample,
            positions, mapqs, flags, seq, quals,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chroms, Compression.NONE);
    }

    private SpectralDataset openGenomic(WrittenGenomicRun... runs) {
        Path p = tmp.resolve("g.tio");
        SpectralDataset.create(p.toString(), "g", "ISA-g",
            List.of(), List.of(runs),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return SpectralDataset.open(p.toString());
    }

    private SpectralDataset openAnalytical(String tag, AcquisitionRun... runs) {
        Path p = tmp.resolve(tag + ".tio");
        try (SpectralDataset ds = SpectralDataset.create(p.toString(), tag,
                "ISA-" + tag, List.of(runs), List.of(), List.of(),
                List.of())) {
            assertNotNull(ds);
        }
        return SpectralDataset.open(p.toString());
    }

    // ── genomicRun ──────────────────────────────────────────────────

    @Test
    void genomicRunSoleRunReturnsIt() {
        try (SpectralDataset ds = openGenomic(makeGenomic("ref.fa", "ILLUMINA", "S1"))) {
            GenomicRun gr = RunSelection.genomicRun(ds, null);
            assertEquals(3, gr.readCount());
            assertEquals("ref.fa", gr.referenceUri());
        }
    }

    @Test
    void genomicRunByLayerSelectsNamedRun() {
        try (SpectralDataset ds = openGenomic(
                makeGenomic("a.fa", "ILLUMINA", "SA"),
                makeGenomic("b.fa", "ONT", "SB"))) {
            // Genomic runs are keyed genomic_0001 / genomic_0002.
            GenomicRun gr = RunSelection.genomicRun(ds, "genomic_0002");
            assertEquals("b.fa", gr.referenceUri());
        }
    }

    @Test
    void genomicRunEmptyDatasetThrows() {
        try (SpectralDataset ds = openAnalytical("noms", msRun("only"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.genomicRun(ds, null));
            assertEquals("no genomic runs in dataset", ex.getMessage());
        }
    }

    @Test
    void genomicRunUnknownLayerThrowsWithNames() {
        try (SpectralDataset ds = openGenomic(
                makeGenomic("a.fa", "ILLUMINA", "SA"),
                makeGenomic("b.fa", "ONT", "SB"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.genomicRun(ds, "nope"));
            assertTrue(ex.getMessage().startsWith("genomic run 'nope' not found"),
                ex.getMessage());
            assertTrue(ex.getMessage().contains("genomic_0001"));
        }
    }

    @Test
    void genomicRunAmbiguousWithoutLayerThrows() {
        try (SpectralDataset ds = openGenomic(
                makeGenomic("a.fa", "ILLUMINA", "SA"),
                makeGenomic("b.fa", "ONT", "SB"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.genomicRun(ds, null));
            assertTrue(ex.getMessage().startsWith("multiple genomic runs present"),
                ex.getMessage());
        }
    }

    // ── nmrRun ──────────────────────────────────────────────────────

    @Test
    void nmrRunPrefersNmrClassedRunAmongMixed() {
        try (SpectralDataset ds = openAnalytical("mix",
                msRun("ms_run"), nmrRun("nmr_run"))) {
            AcquisitionRun picked = RunSelection.nmrRun(ds, null);
            assertEquals("nmr_run", picked.name(),
                "NMR-classed run must be preferred over the MS run");
        }
    }

    @Test
    void nmrRunSoleRunFallback() {
        try (SpectralDataset ds = openAnalytical("solnmr", nmrRun("only_nmr"))) {
            AcquisitionRun picked = RunSelection.nmrRun(ds, null);
            assertEquals("only_nmr", picked.name());
        }
    }

    @Test
    void nmrRunByLayerSelectsNamedRun() {
        try (SpectralDataset ds = openAnalytical("mix2",
                msRun("ms_run"), nmrRun("nmr_run"))) {
            AcquisitionRun picked = RunSelection.nmrRun(ds, "ms_run");
            assertEquals("ms_run", picked.name());
        }
    }

    @Test
    void nmrRunUnknownLayerThrows() {
        try (SpectralDataset ds = openAnalytical("mix3",
                msRun("ms_run"), nmrRun("nmr_run"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.nmrRun(ds, "absent"));
            assertTrue(ex.getMessage().startsWith("run 'absent' not found"),
                ex.getMessage());
        }
    }

    @Test
    void nmrRunEmptyDatasetThrows() {
        try (SpectralDataset ds = openGenomic(makeGenomic("a.fa", "ILLUMINA", "S"))) {
            // genomic-only dataset has no analytical (ms) runs
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.nmrRun(ds, null));
            assertEquals("no analytical runs in dataset", ex.getMessage());
        }
    }

    @Test
    void nmrRunAmbiguousNonNmrThrows() {
        try (SpectralDataset ds = openAnalytical("twoms",
                msRun("ms_a"), msRun("ms_b"))) {
            IllegalArgumentException ex = assertThrows(
                IllegalArgumentException.class,
                () -> RunSelection.nmrRun(ds, null));
            assertEquals("multiple runs present; pass --layer <name>",
                ex.getMessage());
        }
    }

    // ── toWritten round-trip ────────────────────────────────────────

    @Test
    void toWrittenRoundTripsFields() {
        try (SpectralDataset ds = openGenomic(
                makeGenomic("hg38.fa", "PACBIO", "PatientX"))) {
            GenomicRun gr = RunSelection.genomicRun(ds, null);
            WrittenGenomicRun w = RunSelection.toWritten(gr);

            assertEquals(3, w.readCount());
            assertEquals("hg38.fa", w.referenceUri());
            assertEquals("PACBIO", w.platform());
            assertEquals("PatientX", w.sampleName());
            assertEquals(AcquisitionMode.GENOMIC_WGS, w.acquisitionMode());
            // Per-read fields round-trip through the read-side accessors.
            assertEquals(100L, w.positions()[0]);
            assertEquals("chr1", w.chromosomes().get(0));
            assertEquals("chr2", w.chromosomes().get(1));
            assertEquals("8M", w.cigars().get(0));
            assertEquals(60, w.mappingQualities()[0] & 0xFF);
            assertEquals(0x10, w.flags()[1]);
        }
    }
}
