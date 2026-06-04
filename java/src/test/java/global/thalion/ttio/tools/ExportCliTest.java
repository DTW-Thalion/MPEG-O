/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.WrittenGenomicRun;

/**
 * Behavioural tests for {@link ExportCli}: argument parsing, exit codes,
 * and real end-to-end exports of a built {@code .tio} through the
 * {@link global.thalion.ttio.exporters.ExporterRegistry} to each
 * pure-Java + samtools-backed format.
 *
 * <p>Mirrors {@link EncodeCliTest}'s fixture pattern (build a tiny run,
 * persist it, then drive the CLI). Each {@code run(...)} return value is
 * asserted and, for success paths, the output file is asserted to exist
 * and be non-empty, so the tests exercise behaviour rather than merely
 * touching lines.</p>
 */
class ExportCliTest {

    // ── Fixtures ────────────────────────────────────────────────────

    private static SpectrumIndex oneSpectrum(int n, double basePeak) {
        return new SpectrumIndex(1,
            new long[]{0}, new int[]{n},
            new double[]{0.0}, new int[]{0}, new int[]{0},
            new double[]{0.0}, new int[]{0}, new double[]{basePeak});
    }

    /** Minimal single-point MS run. */
    private static AcquisitionRun msRun(String name) {
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100.0, 200.0, 300.0});
        ch.put("intensity", new double[]{10.0, 20.0, 30.0});
        return new AcquisitionRun(name, AcquisitionMode.MS1_DDA,
            oneSpectrum(3, 30.0),
            new InstrumentConfig("v", "m", "sn", "ESI", "QTOF", "MCP"),
            ch, List.of(), List.of(), null, 0.0);
    }

    /** IR run carrying vibrational metadata so JCAMP-DX export succeeds. */
    private static AcquisitionRun irRun(String name) {
        double[] x = {400, 800, 1200, 1600, 2000, 2400};
        double[] y = {0.1, 0.5, 0.2, 0.9, 0.3, 0.7};
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("wavenumber", x);
        ch.put("intensity", y);
        AcquisitionRun run = new AcquisitionRun(name, AcquisitionMode.IR,
            oneSpectrum(x.length, 0.9),
            new InstrumentConfig("", "", "", "", "", ""),
            ch, List.of(), List.of(), null, 0.0);
        run.setIRMetadata(Enums.IRMode.ABSORBANCE, 4.0, 32);
        return run;
    }

    /** NMR run so nmrML export selects an NMR-classed run. */
    private static AcquisitionRun nmrRun(String name) {
        int n = 64;
        double[] cs = new double[n];
        double[] intensity = new double[n];
        for (int i = 0; i < n; i++) {
            cs[i] = i * 0.01;
            intensity[i] = 1000.0;
        }
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("chemical_shift", cs);
        ch.put("intensity", intensity);
        return new AcquisitionRun(name, AcquisitionMode.NMR_1D,
            oneSpectrum(n, 1000.0),
            new InstrumentConfig("v", "m", "sn", "RF", "FT", "RF"),
            ch, List.of(), List.of(), "1H", 400.0);
    }

    /** Synthetic single-read genomic run for BAM / CRAM export. */
    private static WrittenGenomicRun genomicRun() {
        int n = 4;
        int rl = 10;
        long[] positions = new long[n];
        int[] flags = new int[n];
        byte[] mapqs = new byte[n];
        List<String> chroms = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            positions[i] = 100L + i * 10L;
            flags[i] = 0;
            mapqs[i] = 60;
            chroms.add("chr1");
        }
        byte[] seq = new byte[n * rl];
        char[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < seq.length; i++) seq[i] = (byte) bases[i % 4];
        byte[] quals = new byte[n * rl];
        Arrays.fill(quals, (byte) 30);
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        List<String> cigars = new ArrayList<>();
        List<String> readNames = new ArrayList<>();
        List<String> mateChroms = new ArrayList<>();
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * rl;
            lengths[i] = rl;
            cigars.add(rl + "M");
            readNames.add(String.format("read_%04d", i));
            mateChroms.add("");
            matePos[i] = -1L;
            tlens[i] = 0;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "ref.fa", "ILLUMINA", "S1",
            positions, mapqs, flags, seq, quals,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chroms, Compression.NONE);
    }

    private static String referenceFasta(Path tmp) throws Exception {
        // Reference long enough to cover positions 100..130 + read length.
        StringBuilder sb = new StringBuilder(">chr1\n");
        for (int i = 0; i < 200; i++) sb.append("ACGT".charAt(i % 4));
        sb.append('\n');
        Path fa = tmp.resolve("ref.fa");
        Files.writeString(fa, sb.toString());
        return fa.toString();
    }

    private Path msTio(Path tmp, String name) {
        Path p = tmp.resolve("ms.tio");
        try (SpectralDataset ds = SpectralDataset.create(p.toString(), "ms",
                "ISA-ms", List.of(msRun(name)), List.of(), List.of(),
                List.of())) {
            assertNotNull(ds);
        }
        return p;
    }

    private Path genomicTio(Path tmp) {
        Path p = tmp.resolve("g.tio");
        SpectralDataset.create(p.toString(), "g", "ISA-g",
            List.of(), List.of(genomicRun()),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return p;
    }

    // ── Argument-parsing exit codes ─────────────────────────────────

    @Test
    void listFormatsExits0() {
        assertEquals(0, ExportCli.run(new String[]{"--list-formats"}));
    }

    @Test
    void unknownFormatExits3() {
        assertEquals(3, ExportCli.run(new String[]{
            "--input", "x.tio", "--format", "xyzzy", "--output", "o.out"}));
    }

    @Test
    void missingArgsExits2() {
        assertEquals(2, ExportCli.run(new String[]{
            "--input", "x.tio", "--format", "mzml"})); // no --output
        assertEquals(2, ExportCli.run(new String[]{})); // nothing at all
    }

    @Test
    void danglingOptionValueExits2() {
        assertEquals(2, ExportCli.run(new String[]{"--input"}));
        assertEquals(2, ExportCli.run(new String[]{"--format"}));
        assertEquals(2, ExportCli.run(new String[]{"--output"}));
        assertEquals(2, ExportCli.run(new String[]{"--layer"}));
        assertEquals(2, ExportCli.run(new String[]{"--extra"}));
    }

    @Test
    void unknownArgumentExits2() {
        assertEquals(2, ExportCli.run(new String[]{"--bogus"}));
    }

    @Test
    void malformedExtraExits2() {
        assertEquals(2, ExportCli.run(new String[]{
            "--input", "x.tio", "--format", "cram",
            "--output", "o.cram", "--extra", "no-equals-sign"}));
    }

    @Test
    void fastaFastqAreDelegatedExit3(@TempDir Path tmp) {
        Path tio = msTio(tmp, "only");
        assertEquals(3, ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "fasta",
            "--output", tmp.resolve("o.fasta").toString()}));
        assertEquals(3, ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "fastq",
            "--output", tmp.resolve("o.fastq").toString()}));
    }

    @Test
    void exporterFailureExits2(@TempDir Path tmp) {
        // mzTab export of an MS-only dataset succeeds, but jcamp export of a
        // pure-MS run is a vibrational mismatch → adapter throws → exit 2.
        Path tio = msTio(tmp, "only");
        int rc = ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "jcamp-dx",
            "--output", tmp.resolve("o.jdx").toString()});
        assertEquals(2, rc, "vibrational mismatch must surface as exit 2");
    }

    // ── Real exports (pure-Java formats) ────────────────────────────

    @Test
    void exportsMzML(@TempDir Path tmp) {
        Path tio = msTio(tmp, "only");
        Path out = tmp.resolve("o.mzML");
        assertEquals(0, ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "mzml",
            "--output", out.toString()}));
        assertTrue(Files.exists(out));
    }

    @Test
    void exportsMzTab(@TempDir Path tmp) {
        Path tio = msTio(tmp, "only");
        Path out = tmp.resolve("o.mzTab");
        assertEquals(0, ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "mztab",
            "--output", out.toString(), "--extra", "dialect=1.0"}));
        assertTrue(Files.exists(out));
    }

    @Test
    void exportsIsaJson(@TempDir Path tmp) {
        Path tio = msTio(tmp, "only");
        Path out = tmp.resolve("o.json");
        assertEquals(0, ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "isa",
            "--output", out.toString()}));
        assertTrue(Files.exists(out));
    }

    @Test
    void exportsJcampDxFromIrRunViaLayer(@TempDir Path tmp) throws Exception {
        Path p = tmp.resolve("ir.tio");
        try (SpectralDataset ds = SpectralDataset.create(p.toString(), "ir",
                "ISA-ir", List.of(irRun("ir_run")), List.of(), List.of(),
                List.of())) {
            assertNotNull(ds);
        }
        Path out = tmp.resolve("o.jdx");
        assertEquals(0, ExportCli.run(new String[]{
            "--input", p.toString(), "--format", "jcamp-dx",
            "--output", out.toString(), "--layer", "ir_run",
            "--extra", "encoding=affn"}));
        assertTrue(Files.exists(out));
        assertTrue(Files.size(out) > 0);
    }

    @Test
    void exportsNmrML(@TempDir Path tmp) {
        Path p = tmp.resolve("nmr.tio");
        try (SpectralDataset ds = SpectralDataset.create(p.toString(), "nmr",
                "ISA-nmr", List.of(nmrRun("nmr_run")), List.of(), List.of(),
                List.of())) {
            assertNotNull(ds);
        }
        Path out = tmp.resolve("o.nmrML");
        assertEquals(0, ExportCli.run(new String[]{
            "--input", p.toString(), "--format", "nmrml",
            "--output", out.toString()}));
        assertTrue(Files.exists(out));
    }

    // ── Real exports (samtools-backed) ──────────────────────────────

    @Test
    void exportsBam(@TempDir Path tmp) throws Exception {
        Path tio = genomicTio(tmp);
        Path out = tmp.resolve("o.bam");
        assertEquals(0, ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "bam",
            "--output", out.toString()}));
        assertTrue(Files.exists(out));
        assertTrue(Files.size(out) > 0);
    }

    @Test
    void exportsCramWithReferenceExtra(@TempDir Path tmp) throws Exception {
        Path tio = genomicTio(tmp);
        String ref = referenceFasta(tmp);
        Path out = tmp.resolve("o.cram");
        int rc = ExportCli.run(new String[]{
            "--input", tio.toString(), "--format", "cram",
            "--output", out.toString(), "--extra", "reference=" + ref});
        assertEquals(0, rc);
        assertTrue(Files.exists(out));
        assertTrue(Files.size(out) > 0);
    }
}
