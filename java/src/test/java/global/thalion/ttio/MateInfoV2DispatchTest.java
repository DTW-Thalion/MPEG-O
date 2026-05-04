/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.codecs.MateInfoV2;
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
 * Task 13 — Java writer/reader dispatch tests for mate_info v2.
 *
 * <p>Mirrors Python {@code test_mate_info_v2_dispatch.py}. Five tests:
 * <ol>
 *   <li>Default v1.7 write produces {@code inline_v2} dataset with
 *       {@code @compression == 13} (MATE_INLINE_V2).</li>
 *   <li>Opt-out writes v1 layout (chrom/pos/tlen child datasets,
 *       no {@code inline_v2}).</li>
 *   <li>{@code signal_codec_overrides[mate_info_*]} rejected when v2 active
 *       (IllegalArgumentException pointing at optDisableInlineMateInfoV2).</li>
 *   <li>{@code signal_codec_overrides[mate_info_*]} allowed when v2 disabled.</li>
 *   <li>v2 round-trip: write + read → mate triple equals input.</li>
 * </ol>
 *
 * <p>All tests skip when the native JNI library is unavailable
 * ({@link MateInfoV2#isAvailable()} returns false).
 *
 * @since v1.7 (Task 13)
 */
final class MateInfoV2DispatchTest {

    private static final int N = 50;
    private static final int READ_LEN = 100;
    private static final int TOTAL = N * READ_LEN;

    /** Matches {@code @EnabledIf} signature: no-arg, returns boolean. */
    static boolean isNativeAvailable() {
        return MateInfoV2.isAvailable();
    }

    /** Build a minimal run with N=50 records of mixed mate patterns.
     *  Pattern: 80% SAME_CHROM ("22"), 10% CROSS_CHROM ("11"),
     *  10% NO_MATE ("*"). */
    private static WrittenGenomicRun buildMinimalRun() {
        return buildMinimalRun(Map.of());
    }

    private static WrittenGenomicRun buildMinimalRun(
            Map<String, Compression> overrides) {
        return buildMinimalRunOptOut(overrides, false);
    }

    private static WrittenGenomicRun buildMinimalRunOptOut(
            Map<String, Compression> overrides, boolean optOut) {
        byte[] seq  = new byte[TOTAL];
        for (int i = 0; i < TOTAL; i++) seq[i] = (byte) 'A';
        byte[] qual = new byte[TOTAL];
        for (int i = 0; i < TOTAL; i++) qual[i] = 30;

        long[] positions = new long[N];
        for (int i = 0; i < N; i++) positions[i] = (long) i * 1000;
        byte[] mapqs = new byte[N];
        java.util.Arrays.fill(mapqs, (byte) 60);
        int[] flags = new int[N];
        long[] offsets = new long[N];
        int[] lengths  = new int[N];
        for (int i = 0; i < N; i++) {
            offsets[i] = (long) i * READ_LEN;
            lengths[i] = READ_LEN;
        }
        List<String> cigars     = new ArrayList<>(N);
        List<String> readNames  = new ArrayList<>(N);
        List<String> chromosomes = new ArrayList<>(N);
        for (int i = 0; i < N; i++) {
            cigars.add(READ_LEN + "M");
            readNames.add("r" + i);
            chromosomes.add("22");
        }

        List<String> mateChromosomes  = new ArrayList<>(N);
        long[] matePositions = new long[N];
        int[]  templateLengths = new int[N];

        long rngSeed = 12345L;
        for (int i = 0; i < N; i++) {
            int d = i % 10;
            if (d < 8) {
                // SAME_CHROM
                mateChromosomes.add("22");
                long delta = (i % 200) - 100;
                matePositions[i] = positions[i] + delta;
                templateLengths[i] = (i % 1000) - 500;
            } else if (d < 9) {
                // CROSS_CHROM
                mateChromosomes.add("11");
                matePositions[i] = (i * 31337L) % 10_000_000L;
                templateLengths[i] = 0;
            } else {
                // NO_MATE
                mateChromosomes.add("*");
                matePositions[i] = 0L;
                templateLengths[i] = 0;
            }
        }

        WrittenGenomicRun run = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA",
            "DISP_TEST",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChromosomes, matePositions,
            templateLengths, chromosomes,
            Compression.NONE,
            overrides);
        if (optOut) {
            run = run.withOptDisableInlineMateInfoV2(true);
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

    // ── Test 1: default v1.7 write produces inline_v2 ───────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void defaultWritesInlineV2(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun();
        Path file = writeRun(tmp, run, "default_v2.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Group mi   = sc.openGroup("mate_info")) {
            assertTrue(mi.hasChild("inline_v2"),
                "v1.7 default should write inline_v2 dataset; "
                + "children: " + mi);
            assertFalse(mi.hasChild("chrom"),
                "v1.7 default must NOT write v1 chrom child dataset");
            assertFalse(mi.hasChild("pos"),
                "v1.7 default must NOT write v1 pos child dataset");
            assertFalse(mi.hasChild("tlen"),
                "v1.7 default must NOT write v1 tlen child dataset");
            try (Hdf5Dataset blobDs = mi.openDataset("inline_v2")) {
                long compressionAttr = blobDs.readIntegerAttribute(
                    "compression", -1L);
                assertEquals(Compression.MATE_INLINE_V2.ordinal(),
                    compressionAttr,
                    "@compression must be MATE_INLINE_V2 = 13, got "
                    + compressionAttr);
                assertEquals(Enums.Precision.UINT8,
                    blobDs.getPrecision(),
                    "inline_v2 dataset must be UINT8");
            }
            assertTrue(mi.hasChild("chrom_names"),
                "chrom_names sidecar must be present");
        }
    }

    // ── Test 2: opt-out writes v1 layout ────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void optOutWritesV1Layout(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun()
            .withOptDisableInlineMateInfoV2(true);
        Path file = writeRun(tmp, run, "optout_v1.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels")) {
            // With no mate_info_* override and opt-out, the M82
            // compound path is used: mate_info is a dataset, not a group.
            assertFalse(sc.hasChild("inline_v2"),
                "opt-out must NOT write a top-level inline_v2");
            // mate_info should exist as a compound dataset (M82 path).
            // We verify it's openable as a dataset, not a group.
            try (Hdf5Dataset miDs = sc.openDataset("mate_info")) {
                assertNotEquals(Enums.Precision.UINT8, miDs.getPrecision(),
                    "opt-out mate_info must be compound (not UINT8)");
                assertFalse(miDs.hasAttribute("compression"),
                    "opt-out M82 compound must not carry @compression");
            }
        }
    }

    // ── Test 3: signal_codec_overrides[mate_info_*] rejected when v2 active

    @Test
    @EnabledIf("isNativeAvailable")
    void signalCodecOverridesRejectedWhenV2Active(@TempDir Path tmp) {
        // mate_info_pos override while v2 is the default (opt-out=false).
        WrittenGenomicRun run = buildMinimalRun(
            Map.of("mate_info_pos", Compression.RANS_ORDER0));
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> writeRun(tmp, run, "rejected_override.tio"),
            "mate_info_* overrides must be rejected when v2 is active");
        String msg = ex.getMessage();
        assertNotNull(msg, "exception must have a message");
        assertTrue(msg.contains("optDisableInlineMateInfoV2")
                || msg.contains("opt_disable_inline_mate_info_v2")
                || msg.contains("withOptDisableInlineMateInfoV2"),
            "error must point at the opt-out flag; got: " + msg);
        assertTrue(msg.contains("mate_info_pos"),
            "error must name the channel; got: " + msg);
    }

    // ── Test 4: signal_codec_overrides[mate_info_*] allowed under opt-out

    @Test
    @EnabledIf("isNativeAvailable")
    void signalCodecOverridesAllowedWhenV2Disabled(@TempDir Path tmp) {
        // mate_info_pos override with opt-out=true (v1 path).
        WrittenGenomicRun run = buildMinimalRunOptOut(
            Map.of("mate_info_pos", Compression.RANS_ORDER0), true);
        // Should write without throwing.
        Path file = writeRun(tmp, run, "v1_override_ok.tio");
        assertTrue(file.toFile().exists(),
            "file should be written without error when v2 disabled");
        // Verify the v1 subgroup layout was written.
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Group mi   = sc.openGroup("mate_info");
             Hdf5Dataset posDs = mi.openDataset("pos")) {
            assertEquals(Compression.RANS_ORDER0.ordinal(),
                posDs.readIntegerAttribute("compression", -1L),
                "pos @compression must be RANS_ORDER0 when override active");
        }
    }

    // ── Test 5: v2 round-trip — mate triple read back correctly ──────

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RoundTripDefault(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun();
        // Capture expected values before writing.
        List<String> expectedMateChroms  = new ArrayList<>(run.mateChromosomes());
        long[]       expectedMatePos     = run.matePositions().clone();
        int[]        expectedTemplateLens = run.templateLengths().clone();

        Path file = writeRun(tmp, run, "v2_roundtrip.tio");
        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "genomic_0001 must exist");
            assertEquals(N, gr.readCount(), "read count must match");

            for (int i = 0; i < N; i++) {
                AlignedRead rec = gr.readAt(i);
                assertEquals(expectedMateChroms.get(i),
                    rec.mateChromosome(),
                    "read " + i + ": mate_chromosome mismatch");
                assertEquals(expectedMatePos[i],
                    rec.matePosition(),
                    "read " + i + ": mate_position mismatch");
                assertEquals(expectedTemplateLens[i],
                    rec.templateLength(),
                    "read " + i + ": template_length mismatch");
            }
        }
    }
}
