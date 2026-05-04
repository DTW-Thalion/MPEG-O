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

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v1.0 — Java writer/reader dispatch tests for mate_info v2.
 *
 * <p>Mirrors Python {@code test_mate_info_v2_dispatch.py}. Three tests:
 * <ol>
 *   <li>Default v1.0 write produces {@code inline_v2} dataset with
 *       {@code @compression == 13} (MATE_INLINE_V2).</li>
 *   <li>{@code signal_codec_overrides[mate_info_*]} rejected when v2 active
 *       (the only path in v1.0).</li>
 *   <li>v2 round-trip: write + read → mate triple equals input.</li>
 * </ol>
 *
 * <p>All tests skip when the native JNI library is unavailable
 * ({@link MateInfoV2#isAvailable()} returns false).
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

        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.p14", "ILLUMINA",
            "DISP_TEST",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChromosomes, matePositions,
            templateLengths, chromosomes,
            Compression.NONE,
            overrides);
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

    // ── Test 1: default v1.0 write produces inline_v2 ───────────────

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
                "v1.0 default should write inline_v2 dataset; "
                + "children: " + mi);
            assertFalse(mi.hasChild("chrom"),
                "v1.0 default must NOT write v1 chrom child dataset");
            assertFalse(mi.hasChild("pos"),
                "v1.0 default must NOT write v1 pos child dataset");
            assertFalse(mi.hasChild("tlen"),
                "v1.0 default must NOT write v1 tlen child dataset");
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

    // ── Test 2: signal_codec_overrides[mate_info_*] rejected (v2 is the only path)

    @Test
    @EnabledIf("isNativeAvailable")
    void signalCodecOverridesRejected(@TempDir Path tmp) {
        // mate_info_pos override is rejected outright in v1.0 — v2 is
        // the only supported path.
        WrittenGenomicRun run = buildMinimalRun(
            Map.of("mate_info_pos", Compression.RANS_ORDER0));
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> writeRun(tmp, run, "rejected_override.tio"),
            "mate_info_* overrides must be rejected in v1.0");
        String msg = ex.getMessage();
        assertNotNull(msg, "exception must have a message");
        assertTrue(msg.contains("mate_info_pos"),
            "error must name the channel; got: " + msg);
        assertTrue(msg.contains("v2") || msg.contains("inline_v2"),
            "error must mention v2/inline_v2; got: " + msg);
    }

    // ── Test 3: v2 round-trip — mate triple read back correctly ──────

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
