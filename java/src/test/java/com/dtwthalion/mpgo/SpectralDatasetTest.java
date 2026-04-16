/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.*;
import com.dtwthalion.mpgo.hdf5.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M32 acceptance criteria tests.
 */
class SpectralDatasetTest {

    @TempDir
    Path tempDir;

    // ── Round-trip: write + read back ───────────────────────────────

    @Test
    void msRunRoundTrip() {
        String path = tempDir.resolve("ms_roundtrip.mpgo").toString();

        // Build 10 MS spectra
        int specCount = 10;
        int peaksPerSpec = 8;
        int totalPeaks = specCount * peaksPerSpec;
        double[] allMz = new double[totalPeaks];
        double[] allIntensity = new double[totalPeaks];
        long[] offsets = new long[specCount];
        int[] lengths = new int[specCount];
        double[] retentionTimes = new double[specCount];
        int[] msLevels = new int[specCount];
        int[] polarities = new int[specCount];
        double[] precursorMzs = new double[specCount];
        int[] precursorCharges = new int[specCount];
        double[] basePeakIntensities = new double[specCount];

        for (int i = 0; i < specCount; i++) {
            offsets[i] = (long) i * peaksPerSpec;
            lengths[i] = peaksPerSpec;
            retentionTimes[i] = i * 0.5;
            msLevels[i] = 1;
            polarities[i] = 1; // positive
            precursorMzs[i] = 0;
            precursorCharges[i] = 0;
            double maxIntensity = 0;
            for (int j = 0; j < peaksPerSpec; j++) {
                int idx = i * peaksPerSpec + j;
                allMz[idx] = 100.0 + j * 10.0 + i * 0.1;
                allIntensity[idx] = 1000.0 * (j + 1) + i;
                maxIntensity = Math.max(maxIntensity, allIntensity[idx]);
            }
            basePeakIntensities[i] = maxIntensity;
        }

        SpectrumIndex index = new SpectrumIndex(specCount, offsets, lengths,
                retentionTimes, msLevels, polarities, precursorMzs,
                precursorCharges, basePeakIntensities);

        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", allMz);
        channels.put("intensity", allIntensity);

        InstrumentConfig config = new InstrumentConfig(
                "TestCorp", "Model-X", "SN001",
                "ESI", "Orbitrap", "EM");

        AcquisitionRun run = new AcquisitionRun("run_0001",
                AcquisitionMode.MS1_DDA, index, config, channels,
                List.of(), List.of(), null, 0);

        List<Identification> idents = List.of(
                Identification.of("run_0001", 0, "CHEBI:15377", 0.95,
                        List.of("MS2 match", "RT match")));

        List<Quantification> quants = List.of(
                new Quantification("CHEBI:15377", "sample_A", 1234.5, "TIC"));

        List<ProvenanceRecord> prov = List.of(
                ProvenanceRecord.of("mpgo-java-test", Map.of("version", "0.5.0"),
                        List.of(), List.of()));

        // Write
        try (SpectralDataset ds = SpectralDataset.create(path, "Test MS Dataset",
                "ISA-001", List.of(run), idents, quants, prov)) {
            assertNotNull(ds);
        }

        // Read back
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertEquals("Test MS Dataset", ds.title());
            assertEquals("ISA-001", ds.isaInvestigationId());
            assertFalse(ds.featureFlags().isV1Legacy());
            assertTrue(ds.featureFlags().has(FeatureFlags.BASE_V1));

            assertEquals(1, ds.msRuns().size());
            AcquisitionRun readRun = ds.msRuns().get("run_0001");
            assertNotNull(readRun);
            assertEquals(10, readRun.spectrumCount());
            assertEquals(AcquisitionMode.MS1_DDA, readRun.acquisitionMode());

            // Verify spectrum index
            SpectrumIndex readIdx = readRun.spectrumIndex();
            assertEquals(10, readIdx.count());
            assertEquals(0, readIdx.offsets()[0]);
            assertEquals(8, readIdx.lengths()[0]);
            assertEquals(0.0, readIdx.retentionTimes()[0], 1e-10);
            assertEquals(4.5, readIdx.retentionTimes()[9], 1e-10);

            // Verify signal channels
            double[] readMz = readRun.channels().get("mz");
            assertNotNull(readMz);
            assertEquals(totalPeaks, readMz.length);
            assertEquals(allMz[0], readMz[0], 1e-10);
            assertEquals(allMz[totalPeaks - 1], readMz[totalPeaks - 1], 1e-10);

            double[] readIntensity = readRun.channels().get("intensity");
            assertNotNull(readIntensity);
            assertArrayEquals(allIntensity, readIntensity, 1e-10);

            // Verify channel slice for spectrum 5
            double[] slice = readRun.channelSlice("mz", 5);
            assertEquals(peaksPerSpec, slice.length);
            for (int j = 0; j < peaksPerSpec; j++) {
                assertEquals(allMz[5 * peaksPerSpec + j], slice[j], 1e-10);
            }

            // Verify instrument config
            assertNotNull(readRun.instrumentConfig());
            assertEquals("TestCorp", readRun.instrumentConfig().manufacturer());
            assertEquals("Orbitrap", readRun.instrumentConfig().analyzerType());
        }
    }

    @Test
    void nmrRunRoundTrip() {
        String path = tempDir.resolve("nmr_roundtrip.mpgo").toString();

        int specCount = 5;
        int pointsPerSpec = 64;
        int totalPoints = specCount * pointsPerSpec;
        double[] allChemShift = new double[totalPoints];
        double[] allIntensity = new double[totalPoints];
        long[] offsets = new long[specCount];
        int[] lengths = new int[specCount];
        double[] retentionTimes = new double[specCount];
        int[] msLevels = new int[specCount];
        int[] polarities = new int[specCount];
        double[] precursorMzs = new double[specCount];
        int[] precursorCharges = new int[specCount];
        double[] basePeaks = new double[specCount];

        for (int i = 0; i < specCount; i++) {
            offsets[i] = (long) i * pointsPerSpec;
            lengths[i] = pointsPerSpec;
            retentionTimes[i] = i * 1.0;
            for (int j = 0; j < pointsPerSpec; j++) {
                int idx = i * pointsPerSpec + j;
                allChemShift[idx] = 0.0 + j * (12.0 / pointsPerSpec);
                allIntensity[idx] = Math.sin(j * 0.1) * 1000;
            }
            basePeaks[i] = 1000;
        }

        SpectrumIndex index = new SpectrumIndex(specCount, offsets, lengths,
                retentionTimes, msLevels, polarities, precursorMzs,
                precursorCharges, basePeaks);

        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("chemical_shift", allChemShift);
        channels.put("intensity", allIntensity);

        AcquisitionRun nmrRun = new AcquisitionRun("nmr_run",
                AcquisitionMode.NMR_1D, index, null, channels,
                List.of(), List.of(), "1H", 600.13);

        try (SpectralDataset ds = SpectralDataset.create(path, "Test NMR",
                null, List.of(nmrRun), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            AcquisitionRun readRun = ds.msRuns().get("nmr_run");
            assertNotNull(readRun);
            assertEquals(AcquisitionMode.NMR_1D, readRun.acquisitionMode());
            assertEquals("1H", readRun.nucleusType());
            assertEquals(600.13, readRun.spectrometerFrequencyMHz(), 1e-10);
            assertEquals(5, readRun.spectrumCount());

            double[] cs = readRun.channels().get("chemical_shift");
            assertNotNull(cs);
            assertEquals(totalPoints, cs.length);
        }
    }

    @Test
    void multiRunDataset() {
        String path = tempDir.resolve("multi_run.mpgo").toString();

        // MS run
        SpectrumIndex msIdx = new SpectrumIndex(2,
                new long[]{0, 4}, new int[]{4, 4},
                new double[]{0.0, 0.5}, new int[]{1, 1},
                new int[]{1, 1}, new double[]{0, 0},
                new int[]{0, 0}, new double[]{1000, 2000});
        Map<String, double[]> msChannels = new LinkedHashMap<>();
        msChannels.put("mz", new double[]{100, 200, 300, 400, 150, 250, 350, 450});
        msChannels.put("intensity", new double[]{10, 20, 30, 40, 15, 25, 35, 45});

        AcquisitionRun msRun = new AcquisitionRun("ms_run", AcquisitionMode.MS1_DDA,
                msIdx, null, msChannels, List.of(), List.of(), null, 0);

        // NMR run
        SpectrumIndex nmrIdx = new SpectrumIndex(1,
                new long[]{0}, new int[]{3},
                new double[]{0}, new int[]{0},
                new int[]{0}, new double[]{0},
                new int[]{0}, new double[]{500});
        Map<String, double[]> nmrChannels = new LinkedHashMap<>();
        nmrChannels.put("chemical_shift", new double[]{1.0, 2.0, 3.0});
        nmrChannels.put("intensity", new double[]{100, 200, 300});

        AcquisitionRun nmrRun = new AcquisitionRun("nmr_run", AcquisitionMode.NMR_1D,
                nmrIdx, null, nmrChannels, List.of(), List.of(), "1H", 400.0);

        try (SpectralDataset ds = SpectralDataset.create(path, "Multi-run",
                null, List.of(msRun, nmrRun), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertEquals(2, ds.msRuns().size());
            assertTrue(ds.msRuns().containsKey("ms_run"));
            assertTrue(ds.msRuns().containsKey("nmr_run"));
            assertEquals(2, ds.msRuns().get("ms_run").spectrumCount());
            assertEquals(1, ds.msRuns().get("nmr_run").spectrumCount());
        }
    }

    @Test
    void chromatogramRoundTrip() {
        String path = tempDir.resolve("chrom_test.mpgo").toString();

        Chromatogram tic = Chromatogram.tic(
                new double[]{0, 1, 2, 3, 4},
                new double[]{100, 200, 150, 300, 250});
        Chromatogram xic = new Chromatogram(
                new double[]{0, 1, 2},
                new double[]{50, 100, 75},
                ChromatogramType.XIC, 500.0, 0, 0);

        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{2},
                new double[]{0}, new int[]{1},
                new int[]{1}, new double[]{0},
                new int[]{0}, new double[]{1000});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100, 200});
        ch.put("intensity", new double[]{1000, 2000});

        AcquisitionRun run = new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(tic, xic), List.of(), null, 0);

        try (SpectralDataset ds = SpectralDataset.create(path, "Chrom Test",
                null, List.of(run), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            AcquisitionRun readRun = ds.msRuns().get("run_0001");
            assertEquals(2, readRun.chromatograms().size());

            Chromatogram readTic = readRun.chromatograms().get(0);
            assertEquals(ChromatogramType.TIC, readTic.type());
            assertEquals(5, readTic.length());
            assertArrayEquals(new double[]{0, 1, 2, 3, 4}, readTic.timeValues(), 1e-10);
            assertArrayEquals(new double[]{100, 200, 150, 300, 250}, readTic.intensityValues(), 1e-10);

            Chromatogram readXic = readRun.chromatograms().get(1);
            assertEquals(ChromatogramType.XIC, readXic.type());
            assertEquals(500.0, readXic.targetMz(), 1e-10);
        }
    }

    @Test
    void featureFlagsRoundTrip() {
        String path = tempDir.resolve("flags_test.mpgo").toString();

        FeatureFlags flags = FeatureFlags.defaultCurrent()
                .with(FeatureFlags.OPT_DIGITAL_SIGNATURES);

        try (SpectralDataset ds = SpectralDataset.create(path, "Flags Test",
                null, List.of(), List.of(), List.of(), List.of(), flags)) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertFalse(ds.featureFlags().isV1Legacy());
            assertEquals("1.1", ds.featureFlags().formatVersion());
            assertTrue(ds.featureFlags().has(FeatureFlags.BASE_V1));
            assertTrue(ds.featureFlags().has(FeatureFlags.OPT_DIGITAL_SIGNATURES));
            assertFalse(ds.featureFlags().has(FeatureFlags.OPT_KEY_ROTATION));
        }
    }

    @Test
    void msImageRoundTrip() {
        String path = tempDir.resolve("image_test.mpgo").toString();

        int w = 4, h = 3, s = 5;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.1;

        MSImage image = new MSImage(w, h, s, 10.0, 10.0, "raster", cube);

        // Write
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            FeatureFlags.defaultCurrent()
                    .with(FeatureFlags.OPT_NATIVE_MSIMAGE_CUBE)
                    .writeTo(root);
            try (Hdf5Group study = root.createGroup("study")) {
                image.writeTo(study);
            }
        }

        // Read back
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            MSImage read = MSImage.readFrom(study);
            assertNotNull(read);
            assertEquals(w, read.width());
            assertEquals(h, read.height());
            assertEquals(s, read.spectralPoints());
            assertEquals(10.0, read.pixelSizeX(), 1e-10);
            assertEquals("raster", read.scanPattern());

            // Verify tile access
            assertEquals(cube[0], read.valueAt(0, 0, 0), 1e-10);
            double[] spectrum = read.spectrumAt(1, 2);
            assertEquals(s, spectrum.length);
            for (int i = 0; i < s; i++) {
                assertEquals(cube[(1 * w + 2) * s + i], spectrum[i], 1e-10);
            }
        }
    }

    // ── Read reference fixtures ─────────────────────────────────────

    @Test
    void readMinimalMsFixture() {
        String fixturePath = getFixturePath("minimal_ms.mpgo");
        try (SpectralDataset ds = SpectralDataset.open(fixturePath)) {
            assertNotNull(ds.featureFlags());
            assertFalse(ds.msRuns().isEmpty());

            // Should have at least one run with 10 spectra
            AcquisitionRun run = ds.msRuns().values().iterator().next();
            assertEquals(10, run.spectrumCount());

            // Read spectrum 5's data via channel slice
            double[] mz = run.channelSlice("mz", 5);
            assertNotNull(mz);
            assertEquals(8, mz.length); // 8 peaks per spectrum
        }
    }

    @Test
    void readFullMsFixture() {
        String fixturePath = getFixturePath("full_ms.mpgo");
        try (SpectralDataset ds = SpectralDataset.open(fixturePath)) {
            assertNotNull(ds);
            assertFalse(ds.msRuns().isEmpty());

            AcquisitionRun run = ds.msRuns().values().iterator().next();
            assertTrue(run.spectrumCount() > 0);

            // M37: fixture carries @identifications_json / @quantifications_json /
            // @provenance_json mirror attributes, so Java recovers the VL-string
            // fields with full fidelity via the JSON attribute path.
            List<Identification> idents = ds.identifications();
            assertEquals(10, idents.size());
            assertEquals("run_0001", idents.get(0).runName());
            assertEquals("CHEBI:15000", idents.get(0).chemicalEntity());
            assertTrue(idents.get(0).evidenceChainJson().contains("MS:1002217"));

            List<Quantification> quants = ds.quantifications();
            assertEquals(5, quants.size());
            assertEquals("CHEBI:15000", quants.get(0).chemicalEntity());
            assertEquals("sample_A", quants.get(0).sampleRef());
            assertEquals("median", quants.get(0).normalizationMethod());

            assertEquals(2, ds.provenanceRecords().size());
            assertNotNull(ds.provenanceRecords().get(0).software());
            assertFalse(ds.provenanceRecords().get(0).software().isEmpty());
        }
    }

    @Test
    void readNmr1dFixture() {
        String fixturePath = getFixturePath("nmr_1d.mpgo");
        try (SpectralDataset ds = SpectralDataset.open(fixturePath)) {
            assertNotNull(ds);
            assertFalse(ds.msRuns().isEmpty());

            // Find the NMR run
            AcquisitionRun nmrRun = null;
            for (AcquisitionRun r : ds.msRuns().values()) {
                if (r.nucleusType() != null) {
                    nmrRun = r;
                    break;
                }
            }
            assertNotNull(nmrRun, "Expected an NMR run in nmr_1d.mpgo");
            assertEquals("1H", nmrRun.nucleusType());
            assertTrue(nmrRun.spectrometerFrequencyMHz() > 0);
        }
    }

    // ── M37: Compound metadata round-trips ──────────────────────────

    @Test
    void identificationsRoundTrip() {
        String path = tempDir.resolve("m37_ids.mpgo").toString();

        List<Identification> idents = List.of(
                Identification.of("run_A", 0, "CHEBI:15377", 0.95,
                        List.of("MS2 match", "RT match")),
                Identification.of("run_B", 3, "CHEBI:17234", 0.88,
                        List.of("fragmentation pattern")),
                Identification.of("run_A", 7, "HMDB:0001234", 0.72,
                        List.of()));

        try (SpectralDataset ds = SpectralDataset.create(path, "ids test", null,
                List.of(), idents, List.of(), List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<Identification> read = ds.identifications();
            assertEquals(3, read.size(), "expected 3 identifications");

            assertEquals("run_A", read.get(0).runName());
            assertEquals(0, read.get(0).spectrumIndex());
            assertEquals("CHEBI:15377", read.get(0).chemicalEntity());
            assertEquals(0.95, read.get(0).confidenceScore(), 1e-12);
            assertTrue(read.get(0).evidenceChainJson().contains("MS2 match"));
            assertTrue(read.get(0).evidenceChainJson().contains("RT match"));

            assertEquals("run_B", read.get(1).runName());
            assertEquals(3, read.get(1).spectrumIndex());
            assertEquals("CHEBI:17234", read.get(1).chemicalEntity());
            assertEquals(0.88, read.get(1).confidenceScore(), 1e-12);

            assertEquals("HMDB:0001234", read.get(2).chemicalEntity());
            assertEquals(0.72, read.get(2).confidenceScore(), 1e-12);
        }
    }

    @Test
    void quantificationsRoundTrip() {
        String path = tempDir.resolve("m37_quants.mpgo").toString();

        List<Quantification> quants = List.of(
                new Quantification("CHEBI:15377", "sample_A", 1234.5, "TIC"),
                new Quantification("CHEBI:17234", "sample_A", 87.2, null),
                new Quantification("HMDB:0001234", "sample_B", 4567.89, "median"));

        try (SpectralDataset ds = SpectralDataset.create(path, "quants test", null,
                List.of(), List.of(), quants, List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<Quantification> read = ds.quantifications();
            assertEquals(3, read.size());

            assertEquals("CHEBI:15377", read.get(0).chemicalEntity());
            assertEquals("sample_A", read.get(0).sampleRef());
            assertEquals(1234.5, read.get(0).abundance(), 1e-12);
            assertEquals("TIC", read.get(0).normalizationMethod());

            assertEquals("CHEBI:17234", read.get(1).chemicalEntity());
            // null or empty string both acceptable for unset normalization
            String n1 = read.get(1).normalizationMethod();
            assertTrue(n1 == null || n1.isEmpty(), "expected null/empty norm, got: " + n1);

            assertEquals(4567.89, read.get(2).abundance(), 1e-12);
            assertEquals("median", read.get(2).normalizationMethod());
        }
    }

    @Test
    void legacyJsonOnlyIdentificationsReadable() {
        // Simulate v0.1/v0.2 file: only @identifications_json, no compound dataset.
        String path = tempDir.resolve("legacy_json_ids.mpgo").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            FeatureFlags.defaultCurrent().writeTo(root);
            try (Hdf5Group study = root.createGroup("study")) {
                study.setStringAttribute("title", "legacy");
                study.setStringAttribute("identifications_json",
                        "[{\"run_name\":\"old_run\",\"spectrum_index\":5,"
                        + "\"chemical_entity\":\"glucose\",\"confidence_score\":0.42,"
                        + "\"evidence_chain\":[\"only match\"]}]");
            }
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<Identification> idents = ds.identifications();
            assertEquals(1, idents.size());
            assertEquals("old_run", idents.get(0).runName());
            assertEquals(5, idents.get(0).spectrumIndex());
            assertEquals("glucose", idents.get(0).chemicalEntity());
            assertEquals(0.42, idents.get(0).confidenceScore(), 1e-12);
            assertTrue(idents.get(0).evidenceChainJson().contains("only match"));
        }
    }

    @Test
    void compoundOnlyRecoversPrimitives() {
        // Simulate a Python/ObjC file with compound dataset but no JSON mirror:
        // Java reads primitives via projection; VL strings decode as empty.
        String path = tempDir.resolve("compound_only.mpgo").toString();

        List<Identification> idents = List.of(
                Identification.of("run_X", 42, "CHEBI:99999", 0.61, List.of("tag")));

        try (SpectralDataset ds = SpectralDataset.create(path, "compound test",
                null, List.of(), idents, List.of(), List.of())) {
            assertNotNull(ds);
        }

        // Strip the JSON mirror to emulate a writer that only emits compound.
        try (Hdf5File f = Hdf5File.open(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            try {
                hdf.hdf5lib.H5.H5Adelete(study.getGroupId(), "identifications_json");
            } catch (hdf.hdf5lib.exceptions.HDF5LibraryException e) {
                fail("could not strip mirror: " + e.getMessage());
            }
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<Identification> read = ds.identifications();
            assertEquals(1, read.size());
            // Primitives recovered via compound projection:
            assertEquals(42, read.get(0).spectrumIndex());
            assertEquals(0.61, read.get(0).confidenceScore(), 1e-12);
            // VL fields decode as empty (documented JHI5 1.10 limitation):
            assertEquals("", read.get(0).runName());
            assertEquals("", read.get(0).chemicalEntity());
        }
    }

    @Test
    void provenanceRoundTrip() {
        String path = tempDir.resolve("m37_prov.mpgo").toString();

        List<ProvenanceRecord> prov = List.of(
                ProvenanceRecord.of("mpgo-java-test", Map.of("version", "0.6.0", "mode", "test"),
                        List.of("input_a", "input_b"), List.of("output_x")),
                ProvenanceRecord.of("tool-b", Map.of(), List.of(), List.of("final_out")));

        try (SpectralDataset ds = SpectralDataset.create(path, "prov test", null,
                List.of(), List.of(), List.of(), prov)) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<ProvenanceRecord> read = ds.provenanceRecords();
            assertEquals(2, read.size());

            assertEquals("mpgo-java-test", read.get(0).software());
            assertTrue(read.get(0).parametersJson().contains("0.6.0"));
            assertTrue(read.get(0).inputRefsJson().contains("input_a"));
            assertTrue(read.get(0).outputRefsJson().contains("output_x"));
            assertTrue(read.get(0).timestampUnix() > 0);

            assertEquals("tool-b", read.get(1).software());
            assertTrue(read.get(1).outputRefsJson().contains("final_out"));
        }
    }

    private static String getFixturePath(String name) {
        // Fixtures are symlinked in test resources
        String resource = SpectralDatasetTest.class.getClassLoader()
                .getResource("mpgo/" + name).getFile();
        return resource;
    }
}
