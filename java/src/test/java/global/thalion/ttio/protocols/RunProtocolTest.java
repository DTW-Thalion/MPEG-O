/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protocols;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Polarity;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Phase 1 + Phase 2 (post-M91) abstraction tests, mirroring the Python
 * {@code tests/test_run_protocol.py}.
 *
 * <p>Phase 1 deliverables:
 * <ul>
 *   <li>{@link Run} interface — both AcquisitionRun and GenomicRun
 *       implement it.</li>
 *   <li>{@code GenomicRun.provenanceChain()} — closes the M91 read-side
 *       gap (no need to fall back to {@code @sample_name}).</li>
 *   <li>{@code SpectralDataset.runsForSample / runsOfModality} —
 *       modality-agnostic accessors.</li>
 * </ul>
 *
 * <p>Phase 2 deliverables:
 * <ul>
 *   <li>{@code SpectralDataset.runs()} — canonical unified mapping.</li>
 *   <li>Mixed-Map {@code create()} overload — a single
 *       {@code Map<String, Object>} carrying both AcquisitionRun and
 *       WrittenGenomicRun, dispatched by {@code instanceof}.</li>
 * </ul>
 */
class RunProtocolTest {

    private static final String SAMPLE_URI = "sample://NA12878";

    // ── Fixture builders ───────────────────────────────────────────

    /** Build a minimal in-memory MS run keyed on {@code SAMPLE_URI}.
     *  Mirrors the Python {@code _make_mixed_dataset} MS branch. */
    private static AcquisitionRun makeMsRun(String name, boolean withSample) {
        int nMs = 3;
        int nPts = 4;
        double[] mz = new double[nMs * nPts];
        double[] intensity = new double[nMs * nPts];
        for (int i = 0; i < nMs; i++) {
            for (int j = 0; j < nPts; j++) {
                int k = i * nPts + j;
                mz[k] = 100.0 + j * (100.0 / (nPts - 1));
                intensity[k] = (k + 1) * 1000.0;
            }
        }
        long[] offsets = new long[nMs];
        int[] lengths = new int[nMs];
        double[] rts = new double[nMs];
        int[] msLevels = new int[nMs];
        int[] pols = new int[nMs];
        double[] pmzs = new double[nMs];
        int[] pcs = new int[nMs];
        double[] bpis = new double[nMs];
        for (int i = 0; i < nMs; i++) {
            offsets[i] = (long) i * nPts;
            lengths[i] = nPts;
            rts[i] = i * 2.0;
            msLevels[i] = 1;
            pols[i] = Polarity.POSITIVE.ordinal();
            bpis[i] = intensity[i * nPts + nPts - 1];
        }
        SpectrumIndex idx = new SpectrumIndex(nMs, offsets, lengths,
            rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> chans = new LinkedHashMap<>();
        chans.put("mz", mz);
        chans.put("intensity", intensity);
        List<ProvenanceRecord> prov = withSample
            ? List.of(new ProvenanceRecord(
                0L, "ms-pipeline", Map.of(),
                List.of(SAMPLE_URI),
                List.of("ms://" + name)))
            : List.of();
        return new AcquisitionRun(name, AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            chans, List.of(), prov, null, 0);
    }

    /** Build a minimal in-memory genomic run keyed on
     *  {@code SAMPLE_URI}. Mirrors the Python {@code _make_mixed_dataset}
     *  genomic branch. Provenance attached when {@code withSample}. */
    private static WrittenGenomicRun makeGenomicRun(boolean withSample) {
        int nG = 4;
        int L = 8;
        long[] positions = {100, 200, 300, 400};
        byte[] mapqs = new byte[nG];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[nG];
        java.util.Arrays.fill(flags, 0x0003);
        byte[] sequences = new byte[nG * L];
        char[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < sequences.length; i++) {
            sequences[i] = (byte) bases[i % 4];
        }
        byte[] qualities = new byte[nG * L];
        java.util.Arrays.fill(qualities, (byte) 30);
        long[] offsets = new long[nG];
        int[] lengths = new int[nG];
        for (int i = 0; i < nG; i++) {
            offsets[i] = (long) i * L;
            lengths[i] = L;
        }
        List<String> cigars = new ArrayList<>();
        List<String> readNames = new ArrayList<>();
        List<String> mateChroms = new ArrayList<>();
        for (int i = 0; i < nG; i++) {
            cigars.add(L + "M");
            readNames.add("r" + i);
            mateChroms.add("");
        }
        long[] matePos = new long[nG];
        java.util.Arrays.fill(matePos, -1L);
        int[] tlens = new int[nG];
        List<String> chroms = List.of("chr1", "chr1", "chr2", "chr2");
        List<ProvenanceRecord> prov = withSample
            ? List.of(new ProvenanceRecord(
                0L, "genomics-pipeline", Map.of(),
                List.of(SAMPLE_URI),
                List.of("genomics://wgs_0001")))
            : List.of();
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mapqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chroms, Compression.ZLIB, Map.of(), prov);
    }

    /** Phase 1 fixture: write a file with both an MS run and a genomic
     *  run, both keyed on {@code SAMPLE_URI}. Returns the file path. */
    private static Path writeMixedDataset(Path tmpFile) {
        AcquisitionRun ms = makeMsRun("ms_0001", true);
        WrittenGenomicRun gr = makeGenomicRun(true);
        SpectralDataset.create(tmpFile.toString(),
            "phase1 fixture", "ISA-PHASE1",
            List.of(ms), List.of(gr),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return tmpFile;
    }

    // ── Phase 1: protocol conformance ──────────────────────────────

    @Test
    void acquisitionRunImplementsRun(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            AcquisitionRun run = ds.msRuns().get("ms_0001");
            assertNotNull(run);
            assertTrue(run instanceof Run,
                "AcquisitionRun must implement the Run interface");
        }
    }

    @Test
    void genomicRunImplementsRun(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            // Java's typed-list create auto-names genomic runs as
            // genomic_NNNN; the writeMixedDataset helper produces one
            // genomic run, so the on-disk name is genomic_0001.
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr);
            assertTrue(gr instanceof Run,
                "GenomicRun must implement the Run interface");
        }
    }

    @Test
    void protocolMethodsCallableUniformly(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            Run msRun = ds.msRuns().get("ms_0001");
            Run gRun = ds.genomicRuns().get("genomic_0001");
            for (Run run : List.of(msRun, gRun)) {
                assertNotNull(run.name());
                assertNotNull(run.acquisitionMode());
                assertTrue(run.count() > 0);
                Object first = run.get(0);
                assertNotNull(first);
                List<ProvenanceRecord> prov = run.provenanceChain();
                assertNotNull(prov);
            }
        }
    }

    // ── Phase 1: GenomicRun.provenanceChain ────────────────────────

    @Test
    void genomicRunHasProvenanceChain(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            List<ProvenanceRecord> chain = gr.provenanceChain();
            assertEquals(1, chain.size());
            assertTrue(chain.get(0).inputRefs().contains(SAMPLE_URI));
            assertEquals("genomics-pipeline", chain.get(0).software());
        }
    }

    @Test
    void emptyGenomicProvenanceReturnsEmpty(@TempDir Path tmp) {
        Path file = tmp.resolve("noprov.tio");
        WrittenGenomicRun gr = makeGenomicRun(false);
        SpectralDataset.create(file.toString(),
            "x", "x",
            List.of(), List.of(gr),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun loaded = ds.genomicRuns().get("genomic_0001");
            assertNotNull(loaded);
            assertEquals(List.of(), loaded.provenanceChain());
        }
    }

    // ── Phase 1: cross-modality helpers ────────────────────────────

    @Test
    void runsForSampleFindsAll(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            Map<String, Run> matching = ds.runsForSample(SAMPLE_URI);
            assertTrue(matching.containsKey("ms_0001"));
            assertTrue(matching.containsKey("genomic_0001"));
            for (Run run : matching.values()) {
                assertTrue(run instanceof Run);
            }
        }
    }

    @Test
    void runsForSampleUnknownReturnsEmpty(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertTrue(ds.runsForSample("sample://UNKNOWN").isEmpty());
        }
    }

    @Test
    void runsOfModalityFiltersByClass(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            Map<String, Run> msOnly = ds.runsOfModality(AcquisitionRun.class);
            Map<String, Run> gOnly = ds.runsOfModality(GenomicRun.class);
            assertEquals(java.util.Set.of("ms_0001"), msOnly.keySet());
            assertEquals(java.util.Set.of("genomic_0001"), gOnly.keySet());
        }
    }

    @Test
    void runsOfModalityReturnsRunValues(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            for (Run run : ds.runsOfModality(AcquisitionRun.class).values()) {
                assertTrue(run instanceof Run);
            }
            for (Run run : ds.runsOfModality(GenomicRun.class).values()) {
                assertTrue(run instanceof Run);
            }
        }
    }

    // ── Phase 2: canonical runs accessor ───────────────────────────

    @Test
    void runsPropertyReturnsUnifiedMapping(@TempDir Path tmp) {
        Path file = writeMixedDataset(tmp.resolve("f.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            Map<String, Run> unified = ds.runs();
            assertTrue(unified.containsKey("ms_0001"));
            assertTrue(unified.containsKey("genomic_0001"));
            for (Run run : unified.values()) {
                assertTrue(run instanceof Run);
            }
        }
    }

    // ── Phase 2: mixed-Map create ──────────────────────────────────

    @Test
    void mixedRunsMapProducesCorrectLayout(@TempDir Path tmp) {
        AcquisitionRun ms = makeMsRun("ms_0001", false);
        WrittenGenomicRun gr = makeGenomicRun(false);

        Path file = tmp.resolve("mixed.tio");
        Map<String, Object> mixed = new LinkedHashMap<>();
        mixed.put("ms_0001", ms);
        mixed.put("genomic_0001", gr);

        SpectralDataset.create(file.toString(),
            "Phase2 mixed write", "ISA-PHASE2",
            mixed,
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertTrue(ds.msRuns().containsKey("ms_0001"));
            assertTrue(ds.genomicRuns().containsKey("genomic_0001"));
            assertTrue(ds.runs().containsKey("ms_0001"));
            assertTrue(ds.runs().containsKey("genomic_0001"));
        }
    }

    @Test
    void legacyTypedListCreateStillWorks(@TempDir Path tmp) {
        // Backward-compat: the typed-list create() continues to work.
        Path file = writeMixedDataset(tmp.resolve("legacy.tio"));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertTrue(ds.msRuns().containsKey("ms_0001"));
            assertTrue(ds.genomicRuns().containsKey("genomic_0001"));
        }
    }

    @Test
    void mixedMapNameCollisionRaises(@TempDir Path tmp) {
        AcquisitionRun ms = makeMsRun("clash", false);
        WrittenGenomicRun gr = makeGenomicRun(false);
        Path file = tmp.resolve("collision.tio");
        Map<String, Object> mixed = new LinkedHashMap<>();
        // Same key -> the second put overwrites the first, so we can't
        // exercise collision via a single Map. Instead test the
        // type-mismatch branch: a name pointing to a non-Run value.
        mixed.put("badtype", "not a run");
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> SpectralDataset.create(file.toString(),
                "x", "x", mixed,
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent()));
        assertTrue(ex.getMessage().contains("unsupported type"),
            "expected unsupported-type message, got: " + ex.getMessage());

        // For the "name in both ms and genomic" case in the Python suite:
        // Python's write_minimal accepts BOTH a runs= and a genomic_runs=
        // kwarg, and the collision is the same name in both. Java's
        // Map<String,Object> mixed-Map cannot represent that (a Map has
        // unique keys), so the equivalent collision is the name-in-both
        // path of the legacy typed-list create. Confirm that mismatch
        // is rejected when the AcquisitionRun key disagrees with its
        // own name() field.
        AcquisitionRun mismatched = makeMsRun("declared_name", false);
        Map<String, Object> bad = new LinkedHashMap<>();
        bad.put("key_does_not_match", mismatched);
        IllegalArgumentException ex2 = assertThrows(
            IllegalArgumentException.class,
            () -> SpectralDataset.create(file.toString(),
                "x", "x", bad,
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent()));
        assertTrue(ex2.getMessage().contains("does not match"),
            "expected name-mismatch message, got: " + ex2.getMessage());
    }

    // ── Phase 2 deviation closure: per-run compound provenance ─────
    //
    // Phase 1 wrote per-run provenance only as a JSON attribute, so
    // Python files (whose writer emits the canonical
    // ``<run>/provenance/steps`` compound dataset) could not round-
    // trip cleanly into Java. Phase 2 closes the gap by:
    //   1. Java now writes BOTH the compound (HDF5 fast path) and
    //      the JSON attribute (non-HDF5 providers + legacy readers).
    //   2. Java's reader prefers the compound and falls back to the
    //      JSON attribute, so Python-only files load correctly.
    //
    // The two tests below exercise the writer (via H5 inspection of
    // the on-disk dataset) and the reader (compound-only by stripping
    // the JSON attribute before re-opening).

    @Test
    void phase2_perRunCompoundDatasetIsWritten(@TempDir Path tmp) throws Exception {
        Path file = writeMixedDataset(tmp.resolve("phase2.tio"));
        // Probe the file directly via the low-level Hdf5 API to confirm
        // that BOTH the MS run and the genomic run carry a
        // /provenance/steps compound dataset (canonical Python layout).
        try (global.thalion.ttio.hdf5.Hdf5File f =
                global.thalion.ttio.hdf5.Hdf5File.openReadOnly(file.toString());
             global.thalion.ttio.hdf5.Hdf5Group root = f.rootGroup();
             global.thalion.ttio.hdf5.Hdf5Group study = root.openGroup("study")) {
            try (global.thalion.ttio.hdf5.Hdf5Group msRuns =
                    study.openGroup("ms_runs");
                 global.thalion.ttio.hdf5.Hdf5Group msRun =
                    msRuns.openGroup("ms_0001");
                 global.thalion.ttio.hdf5.Hdf5Group prov =
                    msRun.openGroup("provenance")) {
                assertTrue(prov.hasChild("steps"),
                    "MS run provenance/steps compound dataset missing");
            }
            try (global.thalion.ttio.hdf5.Hdf5Group gRuns =
                    study.openGroup("genomic_runs");
                 global.thalion.ttio.hdf5.Hdf5Group gRun =
                    gRuns.openGroup("genomic_0001");
                 global.thalion.ttio.hdf5.Hdf5Group prov =
                    gRun.openGroup("provenance")) {
                assertTrue(prov.hasChild("steps"),
                    "genomic run provenance/steps compound dataset missing");
            }
        }
    }

    @Test
    void phase2_readsCompoundWhenJsonAttributeAbsent(@TempDir Path tmp)
            throws Exception {
        Path file = writeMixedDataset(tmp.resolve("phase2-strip.tio"));
        // Strip the provenance_json attribute from BOTH runs so the
        // reader has only the compound dataset to work with — proves
        // the cross-language Python-style read path.
        try (global.thalion.ttio.hdf5.Hdf5File f =
                global.thalion.ttio.hdf5.Hdf5File.open(file.toString());
             global.thalion.ttio.hdf5.Hdf5Group root = f.rootGroup();
             global.thalion.ttio.hdf5.Hdf5Group study = root.openGroup("study")) {
            try (global.thalion.ttio.hdf5.Hdf5Group msRuns =
                    study.openGroup("ms_runs");
                 global.thalion.ttio.hdf5.Hdf5Group msRun =
                    msRuns.openGroup("ms_0001")) {
                msRun.deleteAttribute("provenance_json");
            }
            try (global.thalion.ttio.hdf5.Hdf5Group gRuns =
                    study.openGroup("genomic_runs");
                 global.thalion.ttio.hdf5.Hdf5Group gRun =
                    gRuns.openGroup("genomic_0001")) {
                gRun.deleteAttribute("provenance_json");
            }
        }
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            AcquisitionRun ms = ds.msRuns().get("ms_0001");
            List<ProvenanceRecord> msChain = ms.provenanceChain();
            assertEquals(1, msChain.size(), "MS chain (compound only)");
            assertEquals("ms-pipeline", msChain.get(0).software());
            assertTrue(msChain.get(0).inputRefs().contains(SAMPLE_URI));

            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            List<ProvenanceRecord> gChain = gr.provenanceChain();
            assertEquals(1, gChain.size(), "genomic chain (compound only)");
            assertEquals("genomics-pipeline", gChain.get(0).software());
            assertTrue(gChain.get(0).inputRefs().contains(SAMPLE_URI));
        }
    }
}
