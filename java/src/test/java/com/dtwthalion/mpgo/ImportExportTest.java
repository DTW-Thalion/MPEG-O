/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.*;
import com.dtwthalion.mpgo.importers.*;
import com.dtwthalion.mpgo.exporters.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.file.*;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M33 acceptance criteria tests for import/export.
 */
class ImportExportTest {

    @TempDir
    Path tempDir;

    // ── mzML ────────────────────────────────────────────────────────

    @Test
    void parseTinyPwizMzML() throws Exception {
        String path = getFixturePath("tiny.pwiz.1.1.mzML");
        AcquisitionRun run = MzMLReader.read(path);
        assertNotNull(run, "MzMLReader should produce a run");
        assertTrue(run.spectrumCount() > 0, "Expected at least one spectrum");

        // tiny.pwiz has 4 spectra
        double[] mz = run.channelSlice("mz", 0);
        assertNotNull(mz);
        assertTrue(mz.length > 0);
    }

    @Test
    void parse1minMzML() throws Exception {
        String path = getFixturePath("1min.mzML");
        AcquisitionRun run = MzMLReader.read(path);
        assertNotNull(run);
        assertTrue(run.spectrumCount() > 0);
    }

    @Test
    void mzmlRoundTrip() throws Exception {
        // Read mzML -> write .mpgo -> read back -> write mzML -> compare
        String mzmlPath = getFixturePath("tiny.pwiz.1.1.mzML");
        AcquisitionRun imported = MzMLReader.read(mzmlPath);
        assertNotNull(imported);

        // Write to .mpgo
        String mpgoPath = tempDir.resolve("roundtrip.mpgo").toString();
        try (SpectralDataset ds = SpectralDataset.create(mpgoPath, "Round-trip test",
                null, List.of(imported), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        // Read .mpgo back
        try (SpectralDataset ds = SpectralDataset.open(mpgoPath)) {
            AcquisitionRun readRun = ds.msRuns().values().iterator().next();
            assertEquals(imported.spectrumCount(), readRun.spectrumCount());

            // Compare first spectrum's m/z values
            double[] origMz = imported.channelSlice("mz", 0);
            double[] readMz = readRun.channelSlice("mz", 0);
            assertArrayEquals(origMz, readMz, 1e-10);
        }

        // Write back to mzML
        String outMzml = tempDir.resolve("roundtrip.mzML").toString();
        try (SpectralDataset ds = SpectralDataset.open(mpgoPath)) {
            AcquisitionRun readRun = ds.msRuns().values().iterator().next();
            MzMLWriter.write(readRun, outMzml);
        }

        // Re-read the written mzML
        AcquisitionRun reImported = MzMLReader.read(outMzml);
        assertNotNull(reImported);
        assertEquals(imported.spectrumCount(), reImported.spectrumCount());

        // Compare spectra
        for (int i = 0; i < imported.spectrumCount(); i++) {
            double[] origMz = imported.channelSlice("mz", i);
            double[] reMz = reImported.channelSlice("mz", i);
            assertArrayEquals(origMz, reMz, 1e-10,
                    "m/z mismatch at spectrum " + i);
            double[] origInt = imported.channelSlice("intensity", i);
            double[] reInt = reImported.channelSlice("intensity", i);
            assertArrayEquals(origInt, reInt, 1e-10,
                    "intensity mismatch at spectrum " + i);
        }
    }

    @Test
    void mzmlChromatogramRoundTrip() throws Exception {
        // Create a run with chromatograms, write mzML, read back
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{3},
                new double[]{0.5}, new int[]{1}, new int[]{1},
                new double[]{0}, new int[]{0}, new double[]{1000});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100, 200, 300});
        ch.put("intensity", new double[]{10, 20, 30});

        Chromatogram tic = Chromatogram.tic(
                new double[]{0, 1, 2, 3, 4},
                new double[]{100, 200, 150, 300, 250});

        AcquisitionRun run = new AcquisitionRun("chrom_test", AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(tic), List.of(), null, 0);

        String outPath = tempDir.resolve("chrom.mzML").toString();
        MzMLWriter.write(run, outPath);

        AcquisitionRun reRead = MzMLReader.read(outPath);
        assertNotNull(reRead);
        assertEquals(1, reRead.spectrumCount());
        assertFalse(reRead.chromatograms().isEmpty(), "chromatograms should be present");
        assertEquals(ChromatogramType.TIC, reRead.chromatograms().get(0).type());
        assertEquals(5, reRead.chromatograms().get(0).length());
    }

    @Test
    void indexedMzmlOffsetsAreValid() throws Exception {
        // Write mzML and verify the file is parseable (offsets correct)
        String mzmlPath = getFixturePath("tiny.pwiz.1.1.mzML");
        AcquisitionRun imported = MzMLReader.read(mzmlPath);

        String outPath = tempDir.resolve("indexed.mzML").toString();
        MzMLWriter.write(imported, outPath);

        // Read the file and check <indexListOffset> points to <indexList>
        String content = Files.readString(Path.of(outPath));
        assertTrue(content.contains("<indexListOffset>"));
        assertTrue(content.contains("<indexList"));

        // Extract indexListOffset value
        int iloStart = content.indexOf("<indexListOffset>") + "<indexListOffset>".length();
        int iloEnd = content.indexOf("</indexListOffset>");
        long offset = Long.parseLong(content.substring(iloStart, iloEnd).strip());

        // Verify the byte at that offset is '<' (start of <indexList>)
        byte[] bytes = Files.readAllBytes(Path.of(outPath));
        assertEquals((byte) '<', bytes[(int) offset],
                "indexListOffset should point to '<' of <indexList>");
    }

    // ── nmrML ───────────────────────────────────────────────────────

    @Test
    void parseBmseNmrML() throws Exception {
        String path = getFixturePath("bmse000325.nmrML");
        NmrMLReader.NmrMLResult result = NmrMLReader.read(path);
        assertNotNull(result, "NmrMLReader should produce a result");
        assertNotNull(result.run(), "Should have an acquisition run");
        assertTrue(result.run().spectrumCount() > 0 || result.fid() != null,
                "Should have spectra or FID data");
    }

    @Test
    void nmrmlRoundTrip() throws Exception {
        // Create NMR data, write nmrML, read back, verify
        int points = 64;
        double[] chemShift = new double[points];
        double[] intensity = new double[points];
        for (int i = 0; i < points; i++) {
            chemShift[i] = i * (12.0 / points);
            intensity[i] = Math.sin(i * 0.2) * 1000;
        }

        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{points},
                new double[]{0}, new int[]{0}, new int[]{0},
                new double[]{0}, new int[]{0}, new double[]{1000});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("chemical_shift", chemShift);
        channels.put("intensity", intensity);

        AcquisitionRun run = new AcquisitionRun("nmr_test", AcquisitionMode.NMR_1D,
                idx, null, channels, List.of(), List.of(), "1H", 600.13);

        // Write nmrML
        String outPath = tempDir.resolve("roundtrip.nmrML").toString();
        NmrMLWriter.write(run, outPath);

        // Read back
        NmrMLReader.NmrMLResult result = NmrMLReader.read(outPath);
        assertNotNull(result.run());

        // Verify arrays
        double[] readCs = result.run().channels().get("chemical_shift");
        double[] readInt = result.run().channels().get("intensity");
        if (readCs != null) {
            assertEquals(points, readCs.length);
            assertArrayEquals(chemShift, readCs, 1e-10);
            assertArrayEquals(intensity, readInt, 1e-10);
        }
    }

    // ── ISA ─────────────────────────────────────────────────────────

    @Test
    void isaTabExport() throws Exception {
        Path outDir = tempDir.resolve("isa");
        Files.createDirectories(outDir);

        InstrumentConfig config = new InstrumentConfig(
                "TestCorp", "Orbitrap", "SN001", "ESI", "Orbitrap", "EM");
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{2},
                new double[]{0}, new int[]{1}, new int[]{1},
                new double[]{0}, new int[]{0}, new double[]{100});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100, 200});
        ch.put("intensity", new double[]{10, 20});

        AcquisitionRun run = new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, config, ch, List.of(), List.of(), null, 0);

        String mpgoPath = tempDir.resolve("isa_test.mpgo").toString();
        try (SpectralDataset ds = SpectralDataset.create(mpgoPath, "ISA Test",
                "ISA-001", List.of(run), List.of(), List.of(), List.of())) {
            ISAExporter.exportTab(ds, outDir);
        }

        assertTrue(Files.exists(outDir.resolve("i_investigation.txt")));
        assertTrue(Files.exists(outDir.resolve("s_study.txt")));
        assertTrue(Files.exists(outDir.resolve("a_assay_ms_run_0001.txt")));

        String invest = Files.readString(outDir.resolve("i_investigation.txt"));
        assertTrue(invest.contains("Investigation Identifier\tISA-001"));
        assertTrue(invest.contains("Investigation Title\tISA Test"));

        String study = Files.readString(outDir.resolve("s_study.txt"));
        assertTrue(study.contains("src_run_0001"));
    }

    @Test
    void isaJsonExport() throws Exception {
        InstrumentConfig config = new InstrumentConfig(
                "TestCorp", "Orbitrap", "SN001", "ESI", "Orbitrap", "EM");
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{2},
                new double[]{0}, new int[]{1}, new int[]{1},
                new double[]{0}, new int[]{0}, new double[]{100});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100, 200});
        ch.put("intensity", new double[]{10, 20});

        AcquisitionRun run = new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, config, ch, List.of(), List.of(), null, 0);

        String mpgoPath = tempDir.resolve("json_test.mpgo").toString();
        try (SpectralDataset ds = SpectralDataset.create(mpgoPath, "JSON Test",
                "ISA-002", List.of(run), List.of(), List.of(), List.of())) {
            String json = ISAExporter.exportJson(ds);
            assertNotNull(json);
            assertTrue(json.contains("\"identifier\""));
            assertTrue(json.contains("ISA-002"));
            assertTrue(json.contains("metabolite profiling"));
            assertTrue(json.contains("Orbitrap"));
        }
    }

    // ── Thermo (M38 delegation) ────────────────────────────────────

    @Test
    void thermoRejectsMissingFile() {
        // M29 stub unconditionally threw UnsupportedOperationException.
        // M38 replaced it with a real delegation that validates the input.
        var ex = assertThrows(java.io.IOException.class,
                () -> ThermoRawReader.read(
                        "/tmp/definitely-missing-mpgo-m38.raw"));
        assertNotNull(ex.getMessage());
    }

    @Test
    void thermoDelegatesToMockBinary() throws Exception {
        Path mockDir = tempDir.resolve("thermo_mock");
        Files.createDirectories(mockDir);

        Path fixtureMzML = Path.of(getFixturePath("tiny.pwiz.1.1.mzML"));
        Path mockBin = mockDir.resolve("mock-parser");
        Files.writeString(mockBin,
                "#!/usr/bin/env bash\n" +
                "set -e\n" +
                "while [ $# -gt 0 ]; do\n" +
                "  case \"$1\" in\n" +
                "    -i) in_path=\"$2\"; shift 2;;\n" +
                "    -o) out_dir=\"$2\"; shift 2;;\n" +
                "    -f) shift 2;;\n" +
                "    *) shift;;\n" +
                "  esac\n" +
                "done\n" +
                "base=$(basename \"$in_path\" .raw)\n" +
                "cp " + fixtureMzML + " \"$out_dir/$base.mzML\"\n");
        mockBin.toFile().setExecutable(true);

        Path raw = mockDir.resolve("sample.raw");
        Files.writeString(raw, "fake raw bytes");

        // Override binary via explicit argument.
        AcquisitionRun run = ThermoRawReader.read(raw.toString(),
                mockBin.toString());
        assertNotNull(run);
        assertTrue(run.spectrumCount() > 0);
    }

    @Test
    void thermoNonzeroExitSurfacesError() throws Exception {
        Path failing = tempDir.resolve("failing-parser");
        Files.writeString(failing, "#!/usr/bin/env bash\nexit 7\n");
        failing.toFile().setExecutable(true);

        Path raw = tempDir.resolve("sample.raw");
        Files.writeString(raw, "fake");

        var ex = assertThrows(java.io.IOException.class,
                () -> ThermoRawReader.read(raw.toString(), failing.toString()));
        assertTrue(ex.getMessage().contains("7") ||
                   ex.getMessage().toLowerCase().contains("thermo"));
    }

    // ── Helpers ─────────────────────────────────────────────────────

    private static String getFixturePath(String name) {
        var url = ImportExportTest.class.getClassLoader().getResource(name);
        if (url == null) throw new RuntimeException("Fixture not found: " + name);
        return url.getFile();
    }
}
