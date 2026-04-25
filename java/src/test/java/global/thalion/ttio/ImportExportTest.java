/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.*;
import global.thalion.ttio.importers.*;
import global.thalion.ttio.exporters.*;
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
    void mzmlMs2ActivationAndIsolationRoundTrip() throws Exception {
        // M74: parse a fixture that carries MS2 precursor activation + an
        // isolation window, and confirm the data propagates through
        // MzMLReader, AcquisitionRun, and SpectrumIndex accessors. Gates
        // that the SRM <product><isolationWindow> inside <chromatogram>
        // does NOT leak into the spectrum's precursor isolation state.
        String path = getFixturePath("tiny.pwiz.1.1.mzML");
        AcquisitionRun run = MzMLReader.read(path);
        assertNotNull(run);

        SpectrumIndex idx = run.spectrumIndex();
        assertNotNull(idx.activationMethods(),
            "M74: activation_methods column must be populated when any "
            + "spectrum carried a recognised activation cvParam");
        assertNotNull(idx.isolationTargetMzs(),
            "M74: isolation_target_mzs column must be populated alongside");
        boolean found = false;
        for (int i = 0; i < idx.count(); i++) {
            if (idx.msLevelAt(i) == 2
                    && idx.activationMethodAt(i) == ActivationMethod.CID) {
                IsolationWindow iw = idx.isolationWindowAt(i);
                if (iw != null && Math.abs(iw.targetMz() - 445.3) < 1e-6) {
                    assertEquals(0.5, iw.lowerOffset(), 1e-6);
                    assertEquals(0.5, iw.upperOffset(), 1e-6);
                    found = true;
                    break;
                }
            }
        }
        assertTrue(found,
            "M74: expected MS2/CID row with isolation target 445.3 (±0.5)");
    }

    @Test
    void mzmlMalformedThrowsMzMLParseException() throws Exception {
        // M50.3: MzMLReader throws MzMLParseException (specific) —
        // not bare Exception — so callers can catch parse failures
        // narrowly. Write a non-mzML file and verify the exception
        // shape + that it extends IOException (for catch (IOException)
        // backward compatibility).
        Path bogus = tempDir.resolve("not-mzml.mzML");
        Files.writeString(bogus, "<not mzml><<garbage>>");
        MzMLParseException thrown = assertThrows(
            MzMLParseException.class,
            () -> MzMLReader.read(bogus.toString()),
            "malformed mzML must throw MzMLParseException specifically");
        assertTrue(thrown instanceof TtioReaderException,
            "MzMLParseException must extend TtioReaderException");
        assertTrue(thrown instanceof java.io.IOException,
            "MzMLParseException must extend IOException for compatibility");
    }

    @Test
    void mzmlRoundTrip() throws Exception {
        // Read mzML -> write .tio -> read back -> write mzML -> compare
        String mzmlPath = getFixturePath("tiny.pwiz.1.1.mzML");
        AcquisitionRun imported = MzMLReader.read(mzmlPath);
        assertNotNull(imported);

        // Write to .tio
        String ttioPath = tempDir.resolve("roundtrip.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(ttioPath, "Round-trip test",
                null, List.of(imported), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        // Read .tio back
        try (SpectralDataset ds = SpectralDataset.open(ttioPath)) {
            AcquisitionRun readRun = ds.msRuns().values().iterator().next();
            assertEquals(imported.spectrumCount(), readRun.spectrumCount());

            // Compare first spectrum's m/z values
            double[] origMz = imported.channelSlice("mz", 0);
            double[] readMz = readRun.channelSlice("mz", 0);
            assertArrayEquals(origMz, readMz, 1e-10);
        }

        // Write back to mzML
        String outMzml = tempDir.resolve("roundtrip.mzML").toString();
        try (SpectralDataset ds = SpectralDataset.open(ttioPath)) {
            AcquisitionRun readRun = ds.msRuns().values().iterator().next();
            MzMLWriter.write(readRun, outMzml);
        }

        // v0.9 M64: Java writer now emits every XSD-required wrapper
        // section and the instrument model cvParam inside
        // <instrumentConfiguration>. Assert the output shape so
        // regressions surface at the unit-test layer (not only when
        // external XSD validators run).
        String written = Files.readString(Path.of(outMzml));
        assertTrue(written.contains("<softwareList"),
                "v0.9 M64: mzML export must emit <softwareList>");
        assertTrue(written.contains("<instrumentConfigurationList"),
                "v0.9 M64: mzML export must emit <instrumentConfigurationList>");
        assertTrue(written.contains("<dataProcessingList"),
                "v0.9 M64: mzML export must emit <dataProcessingList>");
        assertTrue(written.contains("MS:1000031"),
                "v0.9 M64: instrument model cvParam (MS:1000031) required");
        assertTrue(written.contains("defaultInstrumentConfigurationRef=\"IC1\""),
                "v0.9 M64: <run> must reference IC1 via defaultInstrumentConfigurationRef");

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
    void mzmlWriterEmitsM74ActivationAndIsolation() throws Exception {
        // (M74 Slice D) MzMLWriter must consult the SpectrumIndex for
        // activation method + isolation window rather than emitting a
        // CID placeholder. Build a run with one MS1 + one MS2/HCD
        // spectrum, write mzML, and verify:
        //   - HCD accession (MS:1000422) appears for MS2
        //   - CID (MS:1000133) does NOT leak in (proves data-driven emit)
        //   - isolation-window cvParams (MS:1000827/828/829) appear
        //   - re-read through MzMLReader restores the same enum + offsets
        SpectrumIndex idx = new SpectrumIndex(
            2,
            new long[]{0, 3},
            new int[]{3, 2},
            new double[]{0.5, 1.0},
            new int[]{1, 2},
            new int[]{1, 1},
            new double[]{0.0, 445.3},
            new int[]{0, 2},
            new double[]{3.0, 5.0},
            new int[]{
                ActivationMethod.NONE.intValue(),
                ActivationMethod.HCD.intValue()
            },
            new double[]{0.0, 445.3},
            new double[]{0.0, 0.5},
            new double[]{0.0, 0.5}
        );
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100, 200, 300, 150, 250});
        ch.put("intensity", new double[]{1, 2, 3, 4, 5});

        AcquisitionRun run = new AcquisitionRun(
            "m74_run", AcquisitionMode.MS2_DDA,
            idx, null, ch, List.of(), List.of(), null, 0);

        String outPath = tempDir.resolve("m74.mzML").toString();
        MzMLWriter.write(run, outPath, false);

        String xml = Files.readString(Path.of(outPath));
        assertTrue(xml.contains("accession=\"MS:1000422\""),
            "M74: HCD accession must appear for MS2 spectrum");
        assertFalse(xml.contains("accession=\"MS:1000133\""),
            "M74: CID placeholder must not leak into output");
        assertTrue(xml.contains("accession=\"MS:1000827\""),
            "M74: isolation window target m/z cvParam required");
        assertTrue(xml.contains("accession=\"MS:1000828\""),
            "M74: isolation window lower offset cvParam required");
        assertTrue(xml.contains("accession=\"MS:1000829\""),
            "M74: isolation window upper offset cvParam required");

        AcquisitionRun reRead = MzMLReader.read(outPath);
        assertNotNull(reRead);
        SpectrumIndex reIdx = reRead.spectrumIndex();
        assertEquals(ActivationMethod.NONE, reIdx.activationMethodAt(0),
            "MS1 must stay at NONE after round-trip");
        assertEquals(ActivationMethod.HCD, reIdx.activationMethodAt(1),
            "MS2 activation must round-trip as HCD");
        IsolationWindow iw = reIdx.isolationWindowAt(1);
        assertNotNull(iw, "MS2 isolation window must round-trip");
        assertEquals(445.3, iw.targetMz(), 1e-6);
        assertEquals(0.5, iw.lowerOffset(), 1e-6);
        assertEquals(0.5, iw.upperOffset(), 1e-6);
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

        // v0.9 M64: nmrML writer now emits every XSD-required wrapper
        // section + canonical spectrum1D with single interleaved (x,y)
        // <spectrumDataArray>. Assert the output shape so any regression
        // against the XSD content model surfaces here.
        String written = Files.readString(Path.of(outPath));
        assertTrue(written.contains("version=\"1.1.0\""),
                "v0.9 M64: <nmrML> must carry version='1.1.0' attribute");
        assertTrue(written.contains("<fileDescription>"),
                "v0.9 M64: <fileDescription> required by nmrML XSD");
        assertTrue(written.contains("<softwareList>"),
                "v0.9 M64: <softwareList> required before <acquisition>");
        assertTrue(written.contains("<instrumentConfigurationList>"),
                "v0.9 M64: <instrumentConfigurationList> required before <acquisition>");
        assertTrue(written.contains("<DirectDimensionParameterSet"),
                "v0.9 M64: <DirectDimensionParameterSet> required inside acquisition1D");
        assertTrue(written.contains("<sampleContainer"),
                "v0.9 M64: <sampleContainer> required in acquisitionParameterSet");
        assertTrue(written.contains("<sweepWidth"),
                "v0.9 M64: <sweepWidth> replaces the legacy cvParam form");
        assertTrue(written.contains("<irradiationFrequency"),
                "v0.9 M64: <irradiationFrequency> replaces the legacy cvParam form");
        assertTrue(written.contains("numberOfDataPoints=\"" + points + "\""),
                "v0.9 M64: <spectrum1D> must carry numberOfDataPoints attribute");
        assertTrue(written.contains("byteFormat="),
                "v0.9 M64: BinaryDataArrayType byteFormat attribute required");

        // Read back
        NmrMLReader.NmrMLResult result = NmrMLReader.read(outPath);
        assertNotNull(result.run());

        // Verify arrays — interleaved (x,y) round-trips losslessly.
        double[] readCs = result.run().channels().get("chemical_shift");
        double[] readInt = result.run().channels().get("intensity");
        assertNotNull(readCs, "chemical_shift array must round-trip");
        assertNotNull(readInt, "intensity array must round-trip");
        assertEquals(points, readCs.length);
        assertEquals(points, readInt.length);
        assertArrayEquals(chemShift, readCs, 1e-10);
        assertArrayEquals(intensity, readInt, 1e-10);
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

        String ttioPath = tempDir.resolve("isa_test.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(ttioPath, "ISA Test",
                "ISA-001", List.of(run), List.of(), List.of(), List.of())) {
            ISAExporter.exportTab(ds, outDir);
        }

        assertTrue(Files.exists(outDir.resolve("i_investigation.txt")));
        assertTrue(Files.exists(outDir.resolve("s_study.txt")));
        assertTrue(Files.exists(outDir.resolve("a_assay_ms_run_0001.txt")));

        String invest = Files.readString(outDir.resolve("i_investigation.txt"));
        assertTrue(invest.contains("Investigation Identifier\tISA-001"));
        assertTrue(invest.contains("Investigation Title\tISA Test"));

        // v0.9 M64: every ISA-Tab investigation file must include all 11
        // required section headers. isatools halts at the first missing
        // required section — previously only 4 of 11 were emitted.
        for (String section : new String[] {
                "ONTOLOGY SOURCE REFERENCE\n",
                "INVESTIGATION\n",
                "INVESTIGATION PUBLICATIONS\n",
                "INVESTIGATION CONTACTS\n",
                "STUDY\n",
                "STUDY DESIGN DESCRIPTORS\n",
                "STUDY PUBLICATIONS\n",
                "STUDY FACTORS\n",
                "STUDY ASSAYS\n",
                "STUDY PROTOCOLS\n",
                "STUDY CONTACTS\n",
        }) {
            assertTrue(invest.contains(section),
                    "investigation file missing required section: " + section.trim());
        }
        // STUDY PROTOCOLS must declare every Protocol REF used downstream.
        int protocolsStart = invest.indexOf("STUDY PROTOCOLS\n");
        int protocolsEnd = invest.indexOf("STUDY CONTACTS\n", protocolsStart);
        String protocolBlock = invest.substring(protocolsStart, protocolsEnd);
        assertTrue(protocolBlock.contains("sample collection"),
                "STUDY PROTOCOLS must declare 'sample collection'");
        assertTrue(protocolBlock.contains("mass spectrometry"),
                "STUDY PROTOCOLS must declare 'mass spectrometry'");
        // Study Description must be non-empty — isatools rejects empty (4003).
        int descIdx = invest.indexOf("Study Description\t");
        int descEnd = invest.indexOf('\n', descIdx);
        String descValue = invest.substring(
                descIdx + "Study Description\t".length(), descEnd).strip();
        assertFalse(descValue.isEmpty(),
                "Study Description must be non-empty (isatools requires)");

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

        String ttioPath = tempDir.resolve("json_test.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(ttioPath, "JSON Test",
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
                        "/tmp/definitely-missing-ttio-m38.raw"));
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
