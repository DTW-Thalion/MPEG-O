/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.9 M62 cross-language stress + concurrency tests for the Java
 * implementation. Mirrors the per-scenario coverage of
 * {@code python/tests/stress/test_large_file.py} and the ObjC
 * {@code TestStress.m} so the three languages produce comparable
 * timing data.
 *
 * <p>Tests emit "[java-bench]" lines so the cross-language stress
 * harness can scrape them; assertions are loose enough to remain
 * green on slow CI runners.</p>
 *
 * <p>HDF5-only — the Java SpectralDataset entry point doesn't yet
 * dispatch on URL scheme. The provider primitives themselves are
 * tested cross-language by ProviderTest + ProviderPqcTest already.</p>
 */
final class StressTest {

    private static SpectrumIndex makeIndex(int n) {
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        double[] rts = new double[n];
        int[] mls = new int[n];
        int[] pols = new int[n];
        double[] pmzs = new double[n];
        int[] pcs = new int[n];
        double[] bps = new double[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * 16;
            lengths[i] = 16;
            rts[i] = i * 0.06;
            mls[i] = 1;
            pols[i] = 1;
            pmzs[i] = 0.0;
            pcs[i] = 0;
            bps[i] = 1000.0;
        }
        return new SpectrumIndex(n, offsets, lengths, rts, mls, pols, pmzs, pcs, bps);
    }

    private static AcquisitionRun makeRun(int n) {
        SpectrumIndex idx = makeIndex(n);
        Map<String, double[]> channels = new LinkedHashMap<>();
        double[] mz = new double[n * 16];
        double[] intensity = new double[n * 16];
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < 16; j++) {
                int pos = i * 16 + j;
                mz[pos] = 100.0 + i + j * 0.1;
                intensity[pos] = 1000.0 + ((i * 31 + j) % 1000);
            }
        }
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        return new AcquisitionRun("r", AcquisitionMode.MS1_DDA,
                idx, null, channels, List.of(), List.of(), null, 0);
    }

    @Test
    void write_10K_spectra(@TempDir Path tmp) throws Exception {
        Path path = tmp.resolve("write10k.tio");
        long t0 = System.nanoTime();
        AcquisitionRun run = makeRun(10_000);
        try (SpectralDataset ds = SpectralDataset.create(
                path.toString(), "stress", "ISA-STRESS",
                List.of(run), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }
        double elapsedMs = (System.nanoTime() - t0) / 1e6;
        System.out.printf("[java-bench] write 10K spectra HDF5 %.1f ms%n", elapsedMs);
        assertTrue(elapsedMs < 30000.0, "10K write under 30s soft target");
    }

    @Test
    void read_10K_sampled(@TempDir Path tmp) throws Exception {
        Path path = tmp.resolve("read10k.tio");
        try (SpectralDataset ds = SpectralDataset.create(
                path.toString(), "stress", "ISA-STRESS",
                List.of(makeRun(10_000)), List.of(), List.of(), List.of())) {
            // written
        }
        long t0 = System.nanoTime();
        long sampled = 0;
        try (SpectralDataset ds = SpectralDataset.open(path.toString())) {
            AcquisitionRun run = ds.msRuns().get("r");
            assertEquals(10_000, run.spectrumCount());
            for (int i = 0; i < 10_000; i += 100) {
                Spectrum spec = run.objectAtIndex(i);
                sampled += spec.signalArrays().get("mz").length();
            }
        }
        double elapsedMs = (System.nanoTime() - t0) / 1e6;
        System.out.printf("[java-bench] read 100/10K sampled %.1f ms (%d peaks)%n",
                          elapsedMs, sampled);
        assertEquals(100 * 16, sampled);
        assertTrue(elapsedMs < 10_000.0);
    }

    @Test
    void random_access_100(@TempDir Path tmp) throws Exception {
        Path path = tmp.resolve("ra10k.tio");
        try (SpectralDataset ds = SpectralDataset.create(
                path.toString(), "stress", "ISA-STRESS",
                List.of(makeRun(10_000)), List.of(), List.of(), List.of())) {
            // written
        }
        // Deterministic indices so the result is reproducible across runs.
        java.util.Random rng = new java.util.Random(42);
        int[] indices = new int[100];
        for (int i = 0; i < 100; i++) indices[i] = rng.nextInt(10_000);
        long t0 = System.nanoTime();
        long total = 0;
        try (SpectralDataset ds = SpectralDataset.open(path.toString())) {
            AcquisitionRun run = ds.msRuns().get("r");
            for (int idx : indices) {
                total += run.objectAtIndex(idx).signalArrays().get("mz").length();
            }
        }
        double elapsedMs = (System.nanoTime() - t0) / 1e6;
        System.out.printf("[java-bench] random_access_100 %.1f ms%n", elapsedMs);
        assertEquals(100 * 16, total);
        assertTrue(elapsedMs < 5_000.0);
    }

    @Test
    void four_concurrent_readers(@TempDir Path tmp) throws Exception {
        Path path = tmp.resolve("conc.tio");
        try (SpectralDataset ds = SpectralDataset.create(
                path.toString(), "stress", "ISA-STRESS",
                List.of(makeRun(10_000)), List.of(), List.of(), List.of())) {
            // written
        }
        ExecutorService pool = Executors.newFixedThreadPool(4);
        AtomicInteger errors = new AtomicInteger(0);
        long t0 = System.nanoTime();
        try {
            List<Future<Long>> futures = new java.util.ArrayList<>();
            for (int worker = 0; worker < 4; worker++) {
                final int startIndex = worker * 2500;
                futures.add(pool.submit(() -> {
                    try (SpectralDataset ds = SpectralDataset.open(path.toString())) {
                        AcquisitionRun run = ds.msRuns().get("r");
                        long peaks = 0;
                        for (int i = 0; i < 100; i++) {
                            int idx = (startIndex + i) % run.spectrumCount();
                            peaks += run.objectAtIndex(idx).signalArrays().get("mz").length();
                        }
                        return peaks;
                    } catch (Exception e) {
                        errors.incrementAndGet();
                        return 0L;
                    }
                }));
            }
            long total = 0;
            for (Future<Long> f : futures) total += f.get(60, TimeUnit.SECONDS);
            double elapsedMs = (System.nanoTime() - t0) / 1e6;
            System.out.printf("[java-bench] 4 concurrent readers (100 spectra each) %.1f ms%n",
                              elapsedMs);
            assertEquals(0, errors.get(), "no reader thread should have errored");
            assertEquals(4 * 100 * 16, total);
        } finally {
            pool.shutdown();
        }
    }
}
