/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.hdf5.Hdf5File;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Issue #251: the 8 MB HDF5 meta-block (+ 2 MB small-data block) was set
 * unconditionally on every {@code .tio}, bloating small pure-spectral files
 * by ~8 MB of dead free-space. The fix makes the large amortising blocks
 * context-dependent — kept only for metadata-heavy genomic writes, dropped
 * to HDF5 defaults (matching Python/ObjC) for spectral writes.
 *
 * <p>These tests lock in the fix without touching the wire format:</p>
 * <ol>
 *   <li>a pure-spectral {@code .tio} is well under an absolute ceiling
 *       (was ~8 MB+ pre-fix) — an absolute floor, not a ratio, per the
 *       HDF5-metadata-weight-varies lesson;</li>
 *   <li>a genomic write still requests {@code largeBlocks=true} (the
 *       throughput-regression guard), observed via the package-visible
 *       {@link Hdf5File#lastCreateLargeBlocks} test seam;</li>
 *   <li>a pure-spectral write requests {@code largeBlocks=false}.</li>
 * </ol>
 *
 * <p>The seam ({@code Hdf5File.lastCreateLargeBlocks}) is set inside
 * {@code Hdf5File.create(path, largeBlocks)} and records only the hint of
 * the most recent create — it changes no file content or allocation
 * behaviour.</p>
 */
class MetaBlockBloatTest {

    @TempDir
    Path tempDir;

    /** Build a tiny single-MS-run dataset with real signal channels. */
    private AcquisitionRun smallMsRun() {
        int specCount = 4;
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
            polarities[i] = 1;
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
                "TestCorp", "Model-X", "SN001", "ESI", "Orbitrap", "EM");

        return new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                index, config, channels, List.of(), List.of(), null, 0);
    }

    /** An embed-reference genomic run with zero reads — enough to drive
     *  the genomic create path (and the OPT_GENOMIC branch in createMixed)
     *  without the native ref-diff JNI library. Mirrors
     *  {@code ReferencesAccessorTest}. */
    private WrittenGenomicRun emptyGenomicRun() {
        Map<String, byte[]> refSeqs = new LinkedHashMap<>();
        refSeqs.put("chr1", "ACGTACGTACGT".getBytes());
        refSeqs.put("chr2", "TTTTAAAACCCC".getBytes());
        return new WrittenGenomicRun(
                AcquisitionMode.GENOMIC_WGS,
                "test-ref-v1", "ILLUMINA", "REF_TEST",
                new long[0], new byte[0], new int[0],
                new byte[0], new byte[0],
                new long[0], new int[0],
                List.of(), List.of(), List.of(),
                new long[0], new int[0],
                List.of(),
                Compression.ZLIB, Map.of(), List.of(),
                true, refSeqs, null);
    }

    // ── Test 1: spectral file is small (locks in the fix) ────────────

    @Test
    void spectralTioIsSmall() throws Exception {
        Path tio = tempDir.resolve("spectral_small.tio");
        try (SpectralDataset ds = SpectralDataset.create(tio.toString(),
                "Spectral", "SPEC001", List.of(smallMsRun()),
                List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }
        long size = Files.size(tio);
        // Absolute ceiling, NOT a ratio. Pre-fix this carried the ~8 MB
        // meta block + 2 MB small-data block of dead space; post-fix it
        // matches the Python/ObjC default-block footprint (well under 2 MB).
        assertTrue(size < 2_000_000L,
                "pure-spectral .tio should be < 2 MB (was ~8 MB+ pre-fix), got "
                + size + " bytes");
    }

    // ── Test 2: genomic still requests the large amortising blocks ───

    @Test
    void genomicWriteRequestsLargeBlocks() throws Exception {
        Hdf5File.resetLastCreateLargeBlocks(false); // reset the seam
        Path tio = tempDir.resolve("genomic_large.tio");
        SpectralDataset.create(tio.toString(), "Genomic", "GEN001",
                List.of(), List.of(emptyGenomicRun()),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent()).close();
        assertTrue(Hdf5File.lastCreateLargeBlocks(),
                "genomic create path must request largeBlocks=true (8 MB meta "
                + "block) to keep the contig-metadata throughput regime");

        // And it must still round-trip (no correctness change).
        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            assertNotNull(opened.references());
            assertEquals(1, opened.references().size());
        }
    }

    // ── Test 3: pure-spectral write requests default (small) blocks ──

    @Test
    void spectralWriteRequestsSmallBlocks() throws Exception {
        Hdf5File.resetLastCreateLargeBlocks(true); // poison the seam
        Path tio = tempDir.resolve("spectral_seam.tio");
        SpectralDataset.create(tio.toString(), "Spectral", "SPEC002",
                List.of(smallMsRun()), List.of(), List.of(), List.of()).close();
        assertFalse(Hdf5File.lastCreateLargeBlocks(),
                "pure-spectral create path must request largeBlocks=false "
                + "(HDF5 default blocks) so small files don't carry 8 MB dead space");
    }
}
