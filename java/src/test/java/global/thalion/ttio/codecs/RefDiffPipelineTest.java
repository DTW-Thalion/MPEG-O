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

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * End-to-end M93 REF_DIFF pipeline tests via SpectralDataset.create / open.
 *
 * <p>Mirrors Python's {@code test_m93_ref_diff_pipeline.py} one-for-one.
 */
final class RefDiffPipelineTest {

    // ── Builders ─────────────────────────────────────────────────────

    private static byte[] repeat(String unit, int times) {
        byte[] u = unit.getBytes(StandardCharsets.US_ASCII);
        byte[] out = new byte[u.length * times];
        for (int i = 0; i < times; i++) {
            System.arraycopy(u, 0, out, i * u.length, u.length);
        }
        return out;
    }

    private static byte[] md5(byte[] data) {
        try {
            return MessageDigest.getInstance("MD5").digest(data);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static String hex(byte[] buf) {
        StringBuilder sb = new StringBuilder(buf.length * 2);
        for (byte b : buf) sb.append(String.format("%02x", b & 0xFF));
        return sb.toString();
    }

    private static WrittenGenomicRun buildRefDiffRun(
            String referenceUri, byte[] refSeq, boolean embed) {
        int n = 5;
        if (refSeq == null) refSeq = repeat("ACGTACGTAC", 100);
        byte[] seqUnit = "ACGTACGTAC".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * seqUnit.length];
        for (int i = 0; i < n; i++) {
            System.arraycopy(seqUnit, 0, sequences,
                i * seqUnit.length, seqUnit.length);
        }
        byte[] qualities = new byte[sequences.length];
        java.util.Arrays.fill(qualities, (byte) 30);
        long[] positions = new long[n];
        java.util.Arrays.fill(positions, 1L);
        byte[] mapqs = new byte[n];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[n];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * seqUnit.length;
            lengths[i] = seqUnit.length;
        }
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        List<String> chroms = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add("10M");
            readNames.add("r" + i);
            mateChroms.add("*");
            chroms.add("22");
            matePos[i] = -1L;
        }
        Map<String, Compression> overrides =
            Map.of("sequences", Compression.REF_DIFF);
        Map<String, byte[]> chromSeqs = embed
            ? Map.of("22", refSeq) : null;
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, referenceUri, "ILLUMINA", "test",
            positions, mapqs, flags, sequences, qualities, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            Compression.ZLIB, overrides, List.of(),
            embed, chromSeqs, null, false, false, false, false);
    }

    private static WrittenGenomicRun buildM82OnlyRun() {
        int n = 3;
        byte[] seqUnit = "ACGTACGT".getBytes(StandardCharsets.US_ASCII);
        byte[] sequences = new byte[n * seqUnit.length];
        for (int i = 0; i < n; i++) {
            System.arraycopy(seqUnit, 0, sequences,
                i * seqUnit.length, seqUnit.length);
        }
        byte[] qualities = new byte[sequences.length];
        java.util.Arrays.fill(qualities, (byte) 25);
        long[] positions = {1L, 2L, 3L};
        byte[] mapqs = new byte[n];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[n];
        long[] offsets = {0L, 8L, 16L};
        int[] lengths = {8, 8, 8};
        List<String> cigars = List.of("8M", "8M", "8M");
        List<String> readNames = List.of("r0", "r1", "r2");
        List<String> mateChroms = List.of("*", "*", "*");
        List<String> chroms = List.of("22", "22", "22");
        long[] matePos = {-1L, -1L, -1L};
        int[] tlens = new int[n];
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "m82-only-uri", "ILLUMINA", "m82",
            positions, mapqs, flags, sequences, qualities, offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chroms,
            Compression.ZLIB);
    }

    private static Path writeRun(Path tmp, String fname,
                                 Map<String, WrittenGenomicRun> runs) {
        Path file = tmp.resolve(fname);
        List<WrittenGenomicRun> list = new ArrayList<>(runs.size());
        List<String> names = new ArrayList<>(runs.size());
        for (var e : runs.entrySet()) {
            list.add(e.getValue());
            names.add(e.getKey());
        }
        // Use the mixed-Map create overload so we get caller-supplied
        // run names (no genomic_NNNN auto-prefix).
        Map<String, Object> mixed = new LinkedHashMap<>();
        for (var e : runs.entrySet()) mixed.put(e.getKey(), e.getValue());
        SpectralDataset.create(file.toString(), "t", "i",
            mixed, List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    // ── 1. Round-trip via REF_DIFF ──────────────────────────────────

    @Test
    void roundTripWithRefDiff(@TempDir Path tmp) {
        WrittenGenomicRun run = buildRefDiffRun("test-ref-uri", null, true);
        Path file = writeRun(tmp, "ref_diff_round_trip.tio",
            Map.of("run_0001", run));
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun out = ds.genomicRuns().get("run_0001");
            assertEquals(5, out.readCount());
            for (int i = 0; i < 5; i++) {
                AlignedRead r = out.readAt(i);
                assertEquals("ACGTACGTAC", r.sequence(),
                    "REF_DIFF round-trip @ read " + i);
            }
        }
    }

    // ── 2. Format version is 1.5 when REF_DIFF used ─────────────────

    @Test
    void formatVersionIs15WhenRefDiff(@TempDir Path tmp) {
        WrittenGenomicRun run = buildRefDiffRun("test-ref-uri", null, true);
        Path file = writeRun(tmp, "fv15.tio", Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup()) {
            String version = root.readStringAttribute("ttio_format_version");
            assertEquals("1.5", version);
        }
    }

    // ── 3. Format version stays 1.4 with M82-only writes ────────────

    @Test
    void formatVersionStays14WithoutRefDiff(@TempDir Path tmp) {
        WrittenGenomicRun run = buildM82OnlyRun();
        Path file = writeRun(tmp, "fv14.tio", Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup()) {
            String version = root.readStringAttribute("ttio_format_version");
            assertEquals("1.4", version);
        }
    }

    // ── 4. Embedded reference at canonical path ─────────────────────

    @Test
    void embeddedReferenceAtCanonicalPath(@TempDir Path tmp) {
        byte[] refSeq = repeat("ACGTACGTAC", 100);
        WrittenGenomicRun run = buildRefDiffRun("test-ref-uri", refSeq, true);
        Path file = writeRun(tmp, "embed.tio", Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group refs = study.openGroup("references");
             Hdf5Group refGrp = refs.openGroup("test-ref-uri")) {
            String md5Hex = refGrp.readStringAttribute("md5");
            assertEquals(hex(md5(refSeq)), md5Hex);
        }
    }

    // ── 5. Two runs sharing reference dedupe to one group ───────────

    @Test
    void twoRunsSharingReferenceDedupe(@TempDir Path tmp) {
        WrittenGenomicRun runA = buildRefDiffRun("shared-uri", null, true);
        WrittenGenomicRun runB = buildRefDiffRun("shared-uri", null, true);
        Map<String, WrittenGenomicRun> runs = new LinkedHashMap<>();
        runs.put("run_a", runA);
        runs.put("run_b", runB);
        Path file = writeRun(tmp, "dedup.tio", runs);
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group refs = study.openGroup("references")) {
            List<String> children = refs.childNames();
            assertEquals(1, children.size(),
                "refs/ should have exactly one child");
            assertEquals("shared-uri", children.get(0));
        }
    }

    // ── 6. Same URI different MD5 → IllegalArgumentException ────────

    @Test
    void sameUriDifferentMd5Throws(@TempDir Path tmp) {
        WrittenGenomicRun runA = buildRefDiffRun(
            "conflict-uri", repeat("ACGTACGTAC", 100), true);
        WrittenGenomicRun runB = buildRefDiffRun(
            "conflict-uri", repeat("TTTTTTTTTT", 100), true);
        Map<String, WrittenGenomicRun> runs = new LinkedHashMap<>();
        runs.put("run_a", runA);
        runs.put("run_b", runB);
        assertThrows(IllegalArgumentException.class,
            () -> writeRun(tmp, "conflict.tio", runs));
    }

    // ── 7. REF_DIFF falls back to BASE_PACK when no ref ─────────────

    @Test
    void refDiffFallsBackToBasePackWithoutRef(@TempDir Path tmp) {
        // Drop reference_chrom_seqs by passing embed=false.
        WrittenGenomicRun run = buildRefDiffRun("test-ref-uri", null, false);
        Path file = writeRun(tmp, "fallback.tio", Map.of("run_0001", run));
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group runs = study.openGroup("genomic_runs");
             Hdf5Group runGrp = runs.openGroup("run_0001");
             Hdf5Group sc = runGrp.openGroup("signal_channels")) {
            // Open the sequences dataset and read its @compression attr.
            var adapter = global.thalion.ttio.providers.Hdf5Provider
                .adapterForGroup(sc);
            try (var ds = adapter.openDataset("sequences")) {
                Object codecAttr = ds.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : -1L;
                assertEquals(Compression.BASE_PACK.ordinal(), codecId,
                    "fallback should stamp BASE_PACK codec id");
            }
        }
    }

    // ── 8. RefMissingException on read after surgical deletion ──────

    @Test
    void refMissingOnReadAfterDeletion(@TempDir Path tmp) throws IOException {
        WrittenGenomicRun run = buildRefDiffRun("test-ref-uri", null, true);
        Path file = writeRun(tmp, "missing_ref.tio",
            Map.of("run_0001", run));
        // Surgically delete the embedded reference group.
        try (Hdf5File f = Hdf5File.open(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group refs = study.openGroup("references")) {
            refs.deleteChild("test-ref-uri");
        }
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun out = ds.genomicRuns().get("run_0001");
            assertThrows(RefMissingException.class,
                () -> out.readAt(0).sequence());
        }
    }
}
