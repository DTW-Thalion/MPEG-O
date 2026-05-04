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
 * Task 12 (#11 ch3) — Java writer/reader dispatch tests for NAME_TOKENIZED v2.
 *
 * <p>Mirrors Python {@code test_name_tok_v2_dispatch.py}. Five tests:
 * <ol>
 *   <li>Default v1.8 write produces {@code signal_channels/read_names} flat
 *       dataset with {@code @compression == 15} (NAME_TOKENIZED_V2).</li>
 *   <li>Opt-out (no override) writes the M82 compound layout (no codec).</li>
 *   <li>Explicit {@code signalCodecOverrides[read_names]=NAME_TOKENIZED}
 *       writes v1 layout with {@code @compression == 8}.</li>
 *   <li>v1 opt-out round-trip: names recovered from M82 compound.</li>
 *   <li>v2 default round-trip: names recovered byte-exact via
 *       {@link NameTokenizerV2}.</li>
 * </ol>
 *
 * <p>All tests skip when the native JNI library is unavailable
 * ({@link NameTokenizerV2#isAvailable()} returns false).
 *
 * @since v1.8 (Task 12 #11 ch3 NAME_TOKENIZED v2)
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
     * @param optDisableV2 when true, sets {@code optDisableNameTokenizedV2=true}
     * @param overrides    signal codec overrides (use Map.of() for default)
     */
    private static WrittenGenomicRun buildMinimalRun(
            boolean optDisableV2,
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

        // signalCompression=NONE so other channels don't need filters; opt
        // out of inline_v2 + ref_diff_v2 to keep the test focused on read_names.
        WrittenGenomicRun run = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS, "GRCh38.dispatch_test", "ILLUMINA",
            "NT_DISP_TEST",
            positions, mapqs, flags, seq, qual, offsets, lengths,
            cigars, readNames, mateChromosomes, matePositions,
            templateLengths, chromosomes,
            Compression.NONE, overrides, List.of(),
            false, null, null,
            true, true, optDisableV2);  // optDisable Inline / RefDiff = true; NameTok configurable
        return run;
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

    // ── Test 1: default v1.8 write produces NAME_TOKENIZED_V2 dataset ──

    @Test
    @EnabledIf("isNativeAvailable")
    void testDefaultWritesV2(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(false, Map.of());
        Path file = writeRun(tmp, run, "default_v2.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs = sc.openDataset("read_names")) {
            assertEquals(Enums.Precision.UINT8, rnDs.getPrecision(),
                "v1.8 default read_names must be UINT8");
            long compressionAttr = rnDs.readIntegerAttribute(
                "compression", -1L);
            assertEquals(Compression.NAME_TOKENIZED_V2.ordinal(),
                compressionAttr,
                "@compression must be NAME_TOKENIZED_V2 = 15, got "
                + compressionAttr);
        }
    }

    // ── Test 2: opt-out + no override writes M82 compound layout ──────

    @Test
    @EnabledIf("isNativeAvailable")
    void testOptOutWritesV1(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(true, Map.of());
        Path file = writeRun(tmp, run, "v1_optout.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs = sc.openDataset("read_names")) {
            // M82 compound: precision is null (compound dataset marker).
            assertNotEquals(Enums.Precision.UINT8, rnDs.getPrecision(),
                "opt-out without override must remain compound, "
                + "not lifted to uint8");
            assertFalse(rnDs.hasAttribute("compression"),
                "M82 compound must not carry @compression");
        }
    }

    // ── Test 3: explicit signal_codec_overrides[read_names] = v1 codec ─

    @Test
    @EnabledIf("isNativeAvailable")
    void testSignalCodecOverridesRespected(@TempDir Path tmp) {
        // Explicit override → v1 layout regardless of opt flag.
        WrittenGenomicRun run = buildMinimalRun(false,
            Map.of("read_names", Compression.NAME_TOKENIZED));
        Path file = writeRun(tmp, run, "v1_explicit.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(file.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group gRuns = study.openGroup("genomic_runs");
             Hdf5Group rg   = gRuns.openGroup("genomic_0001");
             Hdf5Group sc   = rg.openGroup("signal_channels");
             Hdf5Dataset rnDs = sc.openDataset("read_names")) {
            assertEquals(Enums.Precision.UINT8, rnDs.getPrecision(),
                "explicit v1 NAME_TOKENIZED override must produce UINT8");
            long compressionAttr = rnDs.readIntegerAttribute(
                "compression", -1L);
            assertEquals(Compression.NAME_TOKENIZED.ordinal(),
                compressionAttr,
                "@compression must be NAME_TOKENIZED = 8 under explicit "
                + "override, got " + compressionAttr);
        }
    }

    // ── Test 4: v1 opt-out round-trip ─────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testV1RoundTripViaOptOut(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(true, Map.of());
        List<String> expectedNames = new ArrayList<>(run.readNames());
        Path file = writeRun(tmp, run, "v1_rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            GenomicRun gr = ds.genomicRuns().get("genomic_0001");
            assertNotNull(gr, "genomic_0001 must exist");
            assertEquals(N, gr.readCount(), "read count must match");
            for (int i = 0; i < N; i++) {
                AlignedRead rec = gr.readAt(i);
                assertEquals(expectedNames.get(i), rec.readName(),
                    "v1 opt-out: name at " + i + " must match");
            }
        }
    }

    // ── Test 5: v2 default round-trip ─────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void testV2RoundTripDefault(@TempDir Path tmp) {
        WrittenGenomicRun run = buildMinimalRun(false, Map.of());
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
