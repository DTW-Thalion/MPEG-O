/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.codecs.NameTokenizerV2;
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
 * v1.0 — Java writer/reader dispatch tests for NAME_TOKENIZED v2.
 *
 * <p>Mirrors Python {@code test_name_tok_v2_dispatch.py}. Three tests:
 * <ol>
 *   <li>Default v1.0 write produces {@code signal_channels/read_names} flat
 *       dataset with {@code @compression == 15} (NAME_TOKENIZED_V2).</li>
 *   <li>Explicit {@code signalCodecOverrides[read_names]=NAME_TOKENIZED}
 *       writes v1 layout with {@code @compression == 8}.</li>
 *   <li>v2 default round-trip: names recovered byte-exact via
 *       {@link NameTokenizerV2}.</li>
 * </ol>
 *
 * <p>All tests skip when the native JNI library is unavailable
 * ({@link NameTokenizerV2#isAvailable()} returns false).
 */
final class NameTokenizedV2DispatchTest {

    private static final int N = 100;
    private static final int READ_LEN = 50;
    private static final int TOTAL = N * READ_LEN;

    /** Matches {@code @EnabledIf} signature: no-arg, returns boolean. */
    static boolean isNativeAvailable() {
        return NameTokenizerV2.isAvailable();
    }

    /**
     * Build a minimal run with N=100 records and Illumina-style structured
     * names that exercise the v2 column-aware tokeniser.
     *
     * @param overrides    signal codec overrides (use Map.of() for default)
     */
    private static WrittenGenomicRun buildMinimalRun(
            Map<String, Compression> overrides) {
        long[] positions = new long[N];
        for (int i = 0; i < N; i++) positions[i] = (long) i * 1000L;

        byte[] seq = new byte[TOTAL];
        byte[] cycle = {'A', 'C', 'G', 'T'};
        for (int i = 0; i < TOTAL; i++) seq[i] = cycle[i % 4];
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

        List<String> cigars = new ArrayList<>(N);
        List<String> readNames = new ArrayList<>(N);
        List<String> chromosomes = new ArrayList<>(N);
        List<String> mateChromosomes = new ArrayList<>(N);
        long[] matePositions = new long[N];
        int[] templateLengths = new int[N];
        for (int i = 0; i < N; i++) {
            cigars.add(READ_LEN + "M");
            readNames.add(String.format("INSTR:RUN:1:%d:%d:%d",
                i / 4, i % 4, i * 100));
            chromosomes.add("chr1");
            mateChromosomes.add("*");
            matePositions[i] = -1L;
            templateLengths[i] = 0;
        }

        // signalCompression=NONE so other channels don't need filters.
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.dispatch_test", "ILLUMINA",
            "NT_DISP_TEST",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChromosomes, matePositions,
            templateLengths, chromosomes,
            Compression.NONE, overrides);
    }

    private static Path writeRun(Path tmp, WrittenGenomicRun run,
                                  String fname) {
        Path file = tmp.resolve(fname);
        SpectralDataset.create(file.toString(), "ntv2_dispatch_test",
            "NTV2DISP",
            List.of(), List.of(run), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return file;
    }

    // ── Test 1: default v1.0 write produces NAME_TOKENIZED_V2 dataset ──

    @Test
    @EnabledIf("isNativeAvailable")
    void testDefaultWritesV2(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(Map.of());
        Path file = writeRun(tmp, run, "default_v2.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs = sc.openDataset("read_names")) {
            assertEquals(Enums.Precision.UINT8, rnDs.getPrecision(),
                "v1.0 default read_names must be UINT8");
            long compressionAttr = rnDs.readIntegerAttribute(
                "compression", -1L);
            assertEquals(Compression.NAME_TOKENIZED_V2.ordinal(),
                compressionAttr,
                "@compression must be NAME_TOKENIZED_V2 = 15, got "
                + compressionAttr);
        }
    }

    // ── Test 2: explicit override on read_names is rejected ──────────
    //
    // v1.0 reset Phase 2c: signalCodecOverrides[read_names] is no
    // longer accepted. The v1 NAME_TOKENIZED writer dispatch was
    // removed; v2 (NAME_TOKENIZED_V2 = 15) is the auto-default and
    // only path. Caller-side validation throws IllegalArgumentException.

    @Test
    void testReadNamesOverrideRejected(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(
            Map.of("read_names", Compression.NAME_TOKENIZED));
        Throwable thrown = assertThrows(Throwable.class,
            () -> writeRun(tmp, run, "v1_rejected.tio"));
        Throwable cause = thrown;
        while (cause.getCause() != null && !(cause instanceof IllegalArgumentException)) {
            cause = cause.getCause();
        }
        String msg = cause.getMessage() != null ? cause.getMessage() : "";
        assertTrue(msg.contains("read_names"),
            "rejection must name the channel; got: " + msg);
        assertTrue(msg.contains("v1.0+") || msg.contains("Phase 2c")
                || msg.contains("v2"),
            "rejection should reference the v1.0+ / Phase 2c policy; got: " + msg);
    }

    // ── Test 3: v2 default round-trip ─────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testV2RoundTripDefault(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(Map.of());
        List<String> expectedNames = new ArrayList<>(run.readNames());
        Path file = writeRun(tmp, run, "v2_rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "genomic_0001 must exist");
            assertEquals(N, gr.readCount(), "read count must match");
            for (int i = 0; i < N; i++) {
                AlignedRead rec = gr.readAt(i);
                assertEquals(expectedNames.get(i), rec.readName(),
                    "v2 default: name at " + i + " must match");
            }
        }
    }
}
