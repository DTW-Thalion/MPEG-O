/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.codecs.RefDiffV2;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.hdf5.Hdf5Dataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Task 13 — Java writer/reader dispatch tests for ref_diff v2.
 *
 * <p>Mirrors Python {@code test_ref_diff_v2_dispatch.py}. Five tests:
 * <ol>
 *   <li>Default v1.8 write produces {@code signal_channels/sequences} as a GROUP
 *       containing {@code refdiff_v2} dataset with {@code @compression == 14}
 *       (REF_DIFF_V2).</li>
 *   <li>Opt-out writes v1 layout: {@code sequences} is a flat Dataset with
 *       {@code @compression} in {9, 6}.</li>
 *   <li>Unmapped reads (any cigar="*") prevent v2 → flat BASE_PACK.</li>
 *   <li>v1 round-trip via opt-out: sequences read back correctly.</li>
 *   <li>v2 default round-trip: sequence bytes read back correctly.</li>
 * </ol>
 *
 * <p>All tests skip when the native JNI library is unavailable
 * ({@link RefDiffV2#isAvailable()} returns false).
 *
 * @since v1.8 (Task 13 ref_diff v2)
 */
final class RefDiffV2DispatchTest {

    private static final int N = 50;
    private static final int READ_LEN = 100;
    private static final int TOTAL = N * READ_LEN;

    /** Matches {@code @EnabledIf} signature: no-arg, returns boolean. */
    static boolean isNativeAvailable() {
        return RefDiffV2.isAvailable();
    }

    /**
     * Build a reference long enough to cover all reads.
     * Positions are 1-based; read i starts at (i * 50 + 1).
     * Last read ends at (N-1)*50 + 1 + READ_LEN - 1.
     */
    private static byte[] buildReference() {
        int refLen = (N - 1) * 50 + READ_LEN + 100;
        byte[] ref = new byte[refLen];
        byte[] bases = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < refLen; i++) ref[i] = bases[i % 4];
        return ref;
    }

    /**
     * Build a minimal run with N=50 fully-mapped records.
     * Sequences are exact copies of the reference (0% sub rate).
     * Reference is embedded under "22".
     *
     * @param optOut when true, sets {@code optDisableRefDiffV2=true}
     */
    private static WrittenGenomicRun buildMinimalRun(boolean optOut) {
        return buildMinimalRunWithCigars(optOut, null);
    }

    private static WrittenGenomicRun buildMinimalRunWithCigars(
            boolean optOut, List<String> cigarsOverride) {
        byte[] refSeq = buildReference();
        Map<String, byte[]> chromSeqs = Map.of("22", refSeq);

        long[] positions = new long[N];
        for (int i = 0; i < N; i++) positions[i] = (long) i * 50 + 1L;

        // Sequences: exact copies of the reference slice for each read.
        byte[] seq = new byte[TOTAL];
        for (int i = 0; i < N; i++) {
            int refStart = (int) positions[i] - 1;  // 0-based
            System.arraycopy(refSeq, refStart, seq, i * READ_LEN, READ_LEN);
        }
        byte[] qual = new byte[TOTAL];
        java.util.Arrays.fill(qual, (byte) 30);

        byte[] mapqs = new byte[N];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[N];

        long[] offsets = new long[N];
        int[] lengths = new int[N];
        for (int i = 0; i < N; i++) {
            offsets[i] = (long) i * READ_LEN;
            lengths[i] = READ_LEN;
        }

        List<String> cigars = cigarsOverride != null ? cigarsOverride
            : new ArrayList<>();
        List<String> readNames = new ArrayList<>(N);
        List<String> chromosomes = new ArrayList<>(N);
        List<String> mateChromosomes = new ArrayList<>(N);
        long[] matePositions = new long[N];
        int[] templateLengths = new int[N];

        for (int i = 0; i < N; i++) {
            if (cigarsOverride == null) cigars.add(READ_LEN + "M");
            readNames.add("r" + i);
            chromosomes.add("22");
            mateChromosomes.add("*");
            matePositions[i] = 0L;
            templateLengths[i] = 0;
        }

        // Use ZLIB as the default signalCompression so the v1.5 auto-default
        // (referenceChromSeqs != null → seqCodec = REF_DIFF → writeSequencesRefDiff)
        // kicks in, which is then further branched by optDisableRefDiffV2.
        // This mirrors how real genomic files are written.
        WrittenGenomicRun run = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.dispatch_test", "ILLUMINA",
            "DISP_TEST",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChromosomes, matePositions,
            templateLengths, chromosomes,
            Compression.ZLIB, Map.of(), List.of(),
            true, chromSeqs, null,
            false, false);  // optDisableInlineMateInfoV2=false, optDisableRefDiffV2=false
        if (optOut) {
            run = run.withOptDisableRefDiffV2(true);
        }
        return run;
    }

    private static Path writeRun(Path tmp, WrittenGenomicRun run,
                                  String fname) {
        Path file = tmp.resolve(fname);
        SpectralDataset.create(file.toString(), "dispatch_test",
            "DISP001",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    // ── Test 1: default v1.8 write produces refdiff_v2 group layout ───

    @Test
    @EnabledIf("isNativeAvailable")
    void testDefaultWritesRefDiffV2(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(false);
        Path file = writeRun(tmp, run, "default_v2.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Group seqGrp = sc.openGroup("sequences")) {
            assertTrue(seqGrp.hasChild("refdiff_v2"),
                "v1.8 default must write sequences as a GROUP with "
                + "refdiff_v2 child; children: " + seqGrp);
            try (Hdf5Dataset blobDs = seqGrp.openDataset("refdiff_v2")) {
                long compressionAttr = blobDs.readIntegerAttribute(
                    "compression", -1L);
                assertEquals(Compression.REF_DIFF_V2.ordinal(),
                    compressionAttr,
                    "@compression must be REF_DIFF_V2 = 14, got "
                    + compressionAttr);
                assertEquals(Enums.Precision.UINT8,
                    blobDs.getPrecision(),
                    "refdiff_v2 dataset must be UINT8");
            }
        }
    }

    // ── Test 2: opt-out writes v1 flat dataset ─────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testOptOutWritesV1Layout(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(true);  // opt-out
        Path file = writeRun(tmp, run, "optout_v1.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels")) {
            // sequences must be a Dataset (not a Group) under opt-out.
            try (Hdf5Dataset seqDs = sc.openDataset("sequences")) {
                long compressionAttr = seqDs.readIntegerAttribute(
                    "compression", -1L);
                assertTrue(
                    compressionAttr == Compression.REF_DIFF.ordinal()
                    || compressionAttr == Compression.BASE_PACK.ordinal(),
                    "@compression must be REF_DIFF (9) or BASE_PACK (6) "
                    + "under opt-out, got " + compressionAttr);
                assertEquals(Enums.Precision.UINT8, seqDs.getPrecision(),
                    "opt-out sequences must be UINT8");
            }
        }
    }

    // ── Test 3: unmapped reads prevent v2 → flat BASE_PACK ────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testUnmappedReadsSkipV2(@TempDir Path tmp) {
        // Build a run with one unmapped read (cigar="*").
        List<String> cigarsWithUnmapped = new ArrayList<>();
        for (int i = 0; i < N; i++) {
            cigarsWithUnmapped.add(i == 10 ? "*" : READ_LEN + "M");
        }
        WrittenGenomicRun run = buildMinimalRunWithCigars(
            false, cigarsWithUnmapped);
        Path file = writeRun(tmp, run, "unmapped.tio");

        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels")) {
            // sequences must be a flat Dataset when any cigar="*".
            try (Hdf5Dataset seqDs = sc.openDataset("sequences")) {
                long compressionAttr = seqDs.readIntegerAttribute(
                    "compression", -1L);
                assertEquals(Compression.BASE_PACK.ordinal(),
                    compressionAttr,
                    "unmapped run must fall back to BASE_PACK = 6, "
                    + "got " + compressionAttr);
            }
        }
    }

    // ── Test 4: v1 round-trip via opt-out ─────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testV1RoundTripViaOptOut(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(true);  // opt-out
        byte[] expectedSeq = run.sequences().clone();
        Path file = writeRun(tmp, run, "v1_rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "genomic_0001 must exist");
            assertEquals(N, gr.readCount(), "read count must match");

            byte[] reconstructed = new byte[TOTAL];
            int pos = 0;
            for (int i = 0; i < N; i++) {
                AlignedRead rec = gr.readAt(i);
                byte[] seqBytes = rec.sequence()
                    .getBytes(StandardCharsets.US_ASCII);
                System.arraycopy(seqBytes, 0, reconstructed, pos,
                    seqBytes.length);
                pos += seqBytes.length;
            }
            assertArrayEquals(expectedSeq, reconstructed,
                "v1 opt-out round-trip: sequence bytes must match");
        }
    }

    // ── Test 5: v2 default round-trip ─────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testV2RoundTripDefault(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(false);  // v2 default
        byte[] expectedSeq = run.sequences().clone();
        Path file = writeRun(tmp, run, "v2_rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "genomic_0001 must exist");
            assertEquals(N, gr.readCount(), "read count must match");

            byte[] reconstructed = new byte[TOTAL];
            int pos = 0;
            for (int i = 0; i < N; i++) {
                AlignedRead rec = gr.readAt(i);
                byte[] seqBytes = rec.sequence()
                    .getBytes(StandardCharsets.US_ASCII);
                System.arraycopy(seqBytes, 0, reconstructed, pos,
                    seqBytes.length);
                pos += seqBytes.length;
            }
            assertArrayEquals(expectedSeq, reconstructed,
                "v2 default round-trip: sequence bytes must match");
        }
    }
}
