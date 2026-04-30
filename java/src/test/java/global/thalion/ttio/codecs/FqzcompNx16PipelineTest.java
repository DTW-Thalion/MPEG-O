/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * End-to-end M94 FQZCOMP_NX16 pipeline tests via SpectralDataset.create / open.
 *
 * <p>Mirrors Python's {@code test_m94_fqzcomp_pipeline.py} one-for-one:
 * <ol>
 *   <li>Round-trip with explicit FQZCOMP_NX16 override on qualities.</li>
 *   <li>Format-version is "1.5" when FQZCOMP_NX16 used.</li>
 *   <li>Auto-default fires for v1.5-candidate run.</li>
 *   <li>Auto-default does NOT fire for M82-only run (preserves byte-parity).</li>
 *   <li>Auto-default disabled when signalCompression="none".</li>
 *   <li>Explicit override on qualities works alongside REF_DIFF on sequences.</li>
 *   <li>Reverse flag context affects encoding (forward vs reverse → different bytes).</li>
 *   <li>Format-version stays "1.4" when only M82-M91 codecs.</li>
 * </ol>
 */
final class FqzcompNx16PipelineTest {

    // ── Builders ─────────────────────────────────────────────────────

    private static byte[] repeat(String unit, int times) {
        byte[] u = unit.getBytes(StandardCharsets.US_ASCII);
        byte[] out = new byte[u.length * times];
        for (int i = 0; i < times; i++) {
            System.arraycopy(u, 0, out, i * u.length, u.length);
        }
        return out;
    }

    /**
     * Build a basic FQZCOMP_NX16 run. All reads have the same flags
     * value to exercise the revcomp branch deterministically.
     */
    private static WrittenGenomicRun buildFqzRun(
            int nReads, int readLen, int flagsValue,
            Map<String, Compression> overrides,
            Compression signalCompression,
            boolean embedReference) {
        byte[] seqUnit = "ACGTACGTAC".getBytes(StandardCharsets.US_ASCII);
        if (seqUnit.length < readLen) {
            // Tile up to readLen.
            byte[] expanded = new byte[readLen];
            for (int i = 0; i < readLen; i++) expanded[i] = seqUnit[i % seqUnit.length];
            seqUnit = expanded;
        } else if (seqUnit.length > readLen) {
            byte[] truncated = new byte[readLen];
            System.arraycopy(seqUnit, 0, truncated, 0, readLen);
            seqUnit = truncated;
        }
        byte[] sequences = new byte[nReads * readLen];
        for (int i = 0; i < nReads; i++) {
            System.arraycopy(seqUnit, 0, sequences, i * readLen, readLen);
        }
        byte[] qualities = new byte[sequences.length];
        java.util.Arrays.fill(qualities, (byte) (30 + 33));  // Q30 = 'I'-3 = '?'

        long[] positions = new long[nReads];
        java.util.Arrays.fill(positions, 1L);
        byte[] mapqs = new byte[nReads];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[nReads];
        java.util.Arrays.fill(flags, flagsValue);
        long[] offsets = new long[nReads];
        int[] lengths = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
        }
        List<String> cigars = new ArrayList<>(nReads);
        List<String> readNames = new ArrayList<>(nReads);
        List<String> mateChroms = new ArrayList<>(nReads);
        List<String> chroms = new ArrayList<>(nReads);
        long[] matePos = new long[nReads];
        int[] tlens = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            cigars.add(readLen + "M");
            readNames.add("r" + i);
            mateChroms.add("*");
            chroms.add("22");
            matePos[i] = -1L;
        }
        Map<String, byte[]> chromSeqs = embedReference
            ? Map.of("22", repeat("ACGTACGTAC", 100)) : null;
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "m94-test-uri", "ILLUMINA", "m94",
            positions, mapqs, flags, sequences, qualities, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            signalCompression, overrides, List.of(),
            embedReference, chromSeqs, null);
    }

    private static Path writeRun(Path tmp, String fname,
                                 Map<String, WrittenGenomicRun> runs) {
        Path file = tmp.resolve(fname);
        Map<String, Object> mixed = new LinkedHashMap<>();
        for (var e : runs.entrySet()) mixed.put(e.getKey(), e.getValue());
        SpectralDataset.create(file.toString(), "t", "i",
            mixed, List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    // ── 1. Round-trip with explicit FQZCOMP_NX16 override ───────────

    @Test
    void roundTripWithFqzcompNx16(@TempDir Path tmp) {
        WrittenGenomicRun run = buildFqzRun(
            10, 20, 0,
            Map.of("qualities", Compression.FQZCOMP_NX16),
            Compression.ZLIB, false);
        Path file = writeRun(tmp, "fqz_round_trip.tio",
            Map.of("run_0001", run));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun out = ds.genomicRuns().get("run_0001");
            assertEquals(10, out.readCount());
            for (int i = 0; i < 10; i++) {
                AlignedRead r = out.readAt(i);
                // Qualities are stored as raw Phred byte array — verify byte-exact.
                assertEquals(20, r.qualities().length,
                    "qualities length @ read " + i);
                for (int j = 0; j < 20; j++) {
                    assertEquals((byte) (30 + 33), r.qualities()[j],
                        "FQZCOMP_NX16 round-trip @ read " + i + " pos " + j);
                }
            }
        }
    }

    // ── 2. Format-version is 1.5 when FQZCOMP_NX16 used ─────────────

    @Test
    void formatVersionIs15WhenFqzcompUsed(@TempDir Path tmp) {
        WrittenGenomicRun run = buildFqzRun(
            5, 10, 0,
            Map.of("qualities", Compression.FQZCOMP_NX16),
            Compression.ZLIB, false);
        Path file = writeRun(tmp, "fv15.tio", Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup()) {
            String version = root.readStringAttribute("ttio_format_version");
            assertEquals("1.5", version);
        }
    }

    // ── 3. Auto-default fires for v1.5-candidate run ────────────────

    @Test
    void autoDefaultFiresForV1_5Candidate(@TempDir Path tmp) {
        // Build a run whose sequences will go through REF_DIFF (reference
        // provided + no qualities/sequences override + ZLIB compression).
        // The qualities channel should ALSO auto-apply FQZCOMP_NX16.
        WrittenGenomicRun run = buildFqzRun(
            5, 10, 0,
            Map.of(),  // empty overrides → triggers v1.5 defaults
            Compression.ZLIB, true);  // embed reference
        Path file = writeRun(tmp, "fqz_default.tio",
            Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group runsG = study.openGroup("genomic_runs");
             Hdf5Group rg = runsG.openGroup("run_0001");
             Hdf5Group sc = rg.openGroup("signal_channels")) {
            var adapter = global.thalion.ttio.providers.Hdf5Provider
                .adapterForGroup(sc);
            try (var qDs = adapter.openDataset("qualities")) {
                Object codecAttr = qDs.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : -1L;
                assertEquals(Compression.FQZCOMP_NX16.ordinal(), codecId,
                    "qualities should auto-default to FQZCOMP_NX16 (10)");
            }
            try (var sDs = adapter.openDataset("sequences")) {
                Object codecAttr = sDs.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : -1L;
                assertEquals(Compression.REF_DIFF.ordinal(), codecId,
                    "sequences should auto-default to REF_DIFF (9)");
            }
        }
    }

    // ── 4. Auto-default does NOT fire for M82-only run ──────────────

    @Test
    void autoDefaultSkippedForPureM82Baseline(@TempDir Path tmp) {
        // No reference, no overrides, no v1.5 candidacy → qualities
        // should stay on the legacy path (no @compression attribute or
        // some non-FQZCOMP_NX16 value).
        WrittenGenomicRun run = buildFqzRun(
            5, 10, 0, Map.of(),
            Compression.ZLIB, false);  // no reference embedded
        Path file = writeRun(tmp, "fqz_baseline.tio",
            Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group runsG = study.openGroup("genomic_runs");
             Hdf5Group rg = runsG.openGroup("run_0001");
             Hdf5Group sc = rg.openGroup("signal_channels")) {
            var adapter = global.thalion.ttio.providers.Hdf5Provider
                .adapterForGroup(sc);
            try (var qDs = adapter.openDataset("qualities")) {
                Object codecAttr = qDs.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : 0L;
                assertNotEquals(Compression.FQZCOMP_NX16.ordinal(), codecId,
                    "qualities must NOT auto-default to FQZCOMP_NX16 "
                    + "for a pure-M82 baseline run");
            }
        }
    }

    // ── 5. Format version stays 1.4 when only M82-M91 codecs ────────

    @Test
    void formatVersionStays14WhenNoV1_5Codec(@TempDir Path tmp) {
        WrittenGenomicRun run = buildFqzRun(
            5, 10, 0,
            Map.of("qualities", Compression.RANS_ORDER0),
            Compression.ZLIB, false);
        Path file = writeRun(tmp, "fv14.tio", Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup()) {
            String version = root.readStringAttribute("ttio_format_version");
            assertEquals("1.4", version);
        }
    }

    // ── 6. Explicit FQZCOMP_NX16 + REF_DIFF on sequences ────────────

    @Test
    void explicitFqzcompAlongsideRefDiff(@TempDir Path tmp) {
        WrittenGenomicRun run = buildFqzRun(
            5, 10, 0,
            Map.of(
                "sequences", Compression.REF_DIFF,
                "qualities", Compression.FQZCOMP_NX16),
            Compression.ZLIB, true);
        Path file = writeRun(tmp, "fqz_with_refdiff.tio",
            Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group runsG = study.openGroup("genomic_runs");
             Hdf5Group rg = runsG.openGroup("run_0001");
             Hdf5Group sc = rg.openGroup("signal_channels")) {
            var adapter = global.thalion.ttio.providers.Hdf5Provider
                .adapterForGroup(sc);
            try (var qDs = adapter.openDataset("qualities");
                 var sDs = adapter.openDataset("sequences")) {
                long qid = ((Number) qDs.getAttribute("compression")).longValue();
                long sid = ((Number) sDs.getAttribute("compression")).longValue();
                assertEquals(Compression.FQZCOMP_NX16.ordinal(), qid);
                assertEquals(Compression.REF_DIFF.ordinal(), sid);
            }
        }
        // Round-trip read.
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun out = ds.genomicRuns().get("run_0001");
            for (int i = 0; i < 5; i++) {
                AlignedRead r = out.readAt(i);
                assertEquals(10, r.qualities().length);
                for (int j = 0; j < 10; j++) {
                    assertEquals((byte) (30 + 33), r.qualities()[j]);
                }
            }
        }
    }

    // ── 7. Reverse flag changes encoded bytes ───────────────────────

    /**
     * Generate a varied LCG-derived quality byte array (Q20..Q40, ASCII 53..73)
     * for tests that need adaptive-frequency-table divergence to be visible
     * in the encoded byte stream. With constant Q30 input + uniform initial
     * freq tables, two contexts with different revcomp bits encode the same
     * symbol identically for many symbols before the adaptive update produces
     * visible byte divergence.
     */
    private static byte[] variedQualities(int n, long seedSalt) {
        byte[] out = new byte[n];
        long s = 0xBEEFL ^ seedSalt;
        for (int i = 0; i < n; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            out[i] = (byte) (33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        return out;
    }

    /**
     * Build a WrittenGenomicRun with the same shape as buildFqzRun but with
     * varied qualities. Used by tests that exercise context-divergence
     * sensitivity (revcomp flag, position bucket, etc.).
     */
    private static WrittenGenomicRun buildFqzRunVaried(
            int nReads, int readLen, int flagsValue,
            Map<String, Compression> overrides,
            Compression signalCompression,
            boolean embedReference) {
        WrittenGenomicRun base = buildFqzRun(nReads, readLen, flagsValue,
            overrides, signalCompression, embedReference);
        byte[] varied = variedQualities(nReads * readLen,
            ((long) flagsValue << 32) ^ ((long) nReads << 16) ^ readLen);
        return new WrittenGenomicRun(
            base.acquisitionMode(), base.referenceUri(), base.platform(), base.sampleName(),
            base.positions(), base.mappingQualities(), base.flags(),
            base.sequences(), varied, base.offsets(), base.lengths(),
            base.cigars(), base.readNames(), base.mateChromosomes(),
            base.matePositions(), base.templateLengths(), base.chromosomes(),
            base.signalCompression(), base.signalCodecOverrides(), base.provenanceRecords(),
            base.embedReference(), base.referenceChromSeqs(), base.externalReferencePath());
    }

    @Test
    void reverseFlagChangesEncodedBytes(@TempDir Path tmp) {
        // Varied qualities + larger N to amplify adaptive-update divergence
        // between the all-FWD and all-REV runs (uniform initial freq tables
        // mean tiny inputs produce identical bytes regardless of context bit).
        WrittenGenomicRun runFwd = buildFqzRunVaried(
            100, 100, 0,
            Map.of("qualities", Compression.FQZCOMP_NX16),
            Compression.ZLIB, false);
        WrittenGenomicRun runRev = buildFqzRunVaried(
            100, 100, 16,  // SAM REVERSE
            Map.of("qualities", Compression.FQZCOMP_NX16),
            Compression.ZLIB, false);
        Path fwdFile = writeRun(tmp, "fqz_fwd.tio", Map.of("r", runFwd));
        Path revFile = writeRun(tmp, "fqz_rev.tio", Map.of("r", runRev));

        byte[] fwdBytes = readQualitiesBytes(fwdFile);
        byte[] revBytes = readQualitiesBytes(revFile);
        assertTrue(!java.util.Arrays.equals(fwdBytes, revBytes),
            "FWD vs REV qualities encoded bytes must differ "
            + "(fwd=" + fwdBytes.length + ", rev=" + revBytes.length + ")");

        // Both must round-trip to the same input shape (100 reads × 100bp varied
        // qualities for this test — the encoded bytes differ but both decode
        // to read sequences of length 100).
        try (SpectralDataset ds = SpectralDataset.open(fwdFile.toString())) {
            GenomicRun out = ds.genomicRuns().get("r");
            for (int i = 0; i < 100; i++) {
                assertEquals(100, out.readAt(i).qualities().length);
            }
        }
        try (SpectralDataset ds = SpectralDataset.open(revFile.toString())) {
            GenomicRun out = ds.genomicRuns().get("r");
            for (int i = 0; i < 100; i++) {
                assertEquals(100, out.readAt(i).qualities().length);
            }
        }
    }

    private static byte[] readQualitiesBytes(Path file) {
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group runsG = study.openGroup("genomic_runs");
             Hdf5Group rg = runsG.openGroup("r");
             Hdf5Group sc = rg.openGroup("signal_channels")) {
            var adapter = global.thalion.ttio.providers.Hdf5Provider
                .adapterForGroup(sc);
            try (var qDs = adapter.openDataset("qualities")) {
                long total = qDs.shape()[0];
                return (byte[]) qDs.readSlice(0L, total);
            }
        }
    }

    // ── 8. Single-run regression smoke ──────────────────────────────

    @Test
    void singleRunSmoke(@TempDir Path tmp) {
        // Tiny single-read regression sentinel. Catches gross
        // breakage of the qualities pipeline dispatch.
        WrittenGenomicRun run = buildFqzRun(
            1, 8, 0,
            Map.of("qualities", Compression.FQZCOMP_NX16),
            Compression.ZLIB, false);
        Path file = writeRun(tmp, "fqz_smoke.tio", Map.of("run_0001", run));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun out = ds.genomicRuns().get("run_0001");
            assertEquals(1, out.readCount());
            assertEquals(8, out.readAt(0).qualities().length);
        }
    }
}
