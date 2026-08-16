/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

/**
 * FLOAT_DELTA_ZSTD (codec id 17) — round-trips and the shared golden
 * decode fixture (the cross-language contract per the spec's Option B;
 * Python: test_float_delta_zstd.py, ObjC: TestFloatDeltaZstd.m).
 */
class FloatDeltaZstdTest {

    private static void assertBitExact(double[] a, double[] b) {
        assertEquals(a.length, b.length);
        for (int i = 0; i < a.length; i++) {
            assertEquals(Double.doubleToRawLongBits(a[i]),
                         Double.doubleToRawLongBits(b[i]), "index " + i);
        }
    }

    @Test
    void roundTripsEdgeCases() {
        Random rng = new Random(3);
        int b = FloatDeltaZstd.BLOCK_SIZE;
        double[][] cases = {
            {},
            { 3.14159 },
            java.util.stream.DoubleStream.generate(() -> 7.5).limit(10_000).toArray(),
            java.util.stream.IntStream.range(0, 50_000)
                .mapToDouble(i -> 100.0 + i * 0.038).toArray(),
            java.util.stream.DoubleStream.generate(rng::nextGaussian)
                .limit(50_000).toArray(),
            { 0.0, -0.0, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY,
              Double.NaN, Double.MAX_VALUE, Double.MIN_VALUE, -Double.MIN_VALUE },
            java.util.stream.DoubleStream.generate(rng::nextGaussian)
                .limit(b - 1).toArray(),
            java.util.stream.DoubleStream.generate(rng::nextGaussian)
                .limit(b + 1).toArray(),
        };
        for (double[] c : cases) {
            assertBitExact(c, FloatDeltaZstd.decode(FloatDeltaZstd.encode(c)));
        }
    }

    @Test
    void selectorUsesBothTransforms() {
        double[] grid = java.util.stream.IntStream.range(0, 100_000)
                .mapToDouble(i -> i / 100_000.0).toArray();
        Random rng = new Random(1);
        double[] noise = java.util.stream.DoubleStream
                .generate(rng::nextGaussian).limit(100_000).toArray();
        assertEquals(FloatDeltaZstd.TRANSFORM_DELTA,
                FloatDeltaZstd.encode(grid)[FloatDeltaZstd.HEADER_LEN]);
        assertEquals(FloatDeltaZstd.TRANSFORM_NONE,
                FloatDeltaZstd.encode(noise)[FloatDeltaZstd.HEADER_LEN]);
    }

    @Test
    void rejectsBadMagicAndTruncation() {
        assertThrows(IllegalArgumentException.class,
                () -> FloatDeltaZstd.decode(new byte[FloatDeltaZstd.HEADER_LEN]));
        byte[] enc = FloatDeltaZstd.encode(new double[]{1, 2, 3});
        assertThrows(IllegalArgumentException.class,
                () -> FloatDeltaZstd.decode(
                        java.util.Arrays.copyOf(enc, enc.length - 2)));
    }

    /** Same generator constants as Python's golden_values(). */
    static double[] goldenValues() {
        int n = 4096;
        double[] out = new double[n + n + 6];
        for (int i = 0; i < n; i++) out[i] = 100.0 + 0.25 * i;
        long x = 88172645463325252L;
        for (int i = 0; i < n; i++) {         // xorshift64
            x ^= x << 13;
            x ^= x >>> 7;
            x ^= x << 17;
            out[n + i] = Double.longBitsToDouble(x);
        }
        double[] specials = { 0.0, -0.0, Double.POSITIVE_INFINITY,
                Double.NEGATIVE_INFINITY, Double.NaN, Double.MIN_VALUE };
        System.arraycopy(specials, 0, out, 2 * n, 6);
        return out;
    }

    @Test
    void tioWriteReadRoundTrip(@org.junit.jupiter.api.io.TempDir java.nio.file.Path dir)
            throws Exception {
        int n = 3, p = 4;
        double[] mzAll = new double[n * p];
        double[] intAll = new double[n * p];
        for (int i = 0; i < n * p; i++) {
            mzAll[i] = 100.0 + 0.25 * i;
            intAll[i] = 1000.0 * (i + 1);
        }
        var idx = new global.thalion.ttio.SpectrumIndex(n,
                new long[]{0, 4, 8}, new int[]{4, 4, 4},
                new double[]{1, 2, 3}, new int[]{1, 1, 1},
                new int[]{1, 1, 1}, new double[]{0, 0, 0},
                new int[]{0, 0, 0}, new double[]{1, 1, 1});
        var channels = new java.util.LinkedHashMap<String, double[]>();
        channels.put("mz", mzAll);
        channels.put("intensity", intAll);
        var cfg = new global.thalion.ttio.InstrumentConfig("", "", "", "", "", "");
        var run = new global.thalion.ttio.AcquisitionRun("run_0001",
                global.thalion.ttio.Enums.AcquisitionMode.MS1_DDA, idx, cfg,
                channels, java.util.List.of(), java.util.List.of(), "", 0.0);
        run.setSignalCompression(global.thalion.ttio.Enums.Compression.FLOAT_DELTA_ZSTD);
        String path = dir.resolve("fdz.tio").toString();
        global.thalion.ttio.SpectralDataset.create(path,
                "fdz", "FDZ-TEST", java.util.List.of(run),
                java.util.List.of(), java.util.List.of(),
                java.util.List.of()).close();
        try (var back = global.thalion.ttio.SpectralDataset.open(path)) {
            var r = back.msRuns().get("run_0001");
            assertNotNull(r);
            assertBitExact(mzAll, r.channels().get("mz"));
            assertBitExact(intAll, r.channels().get("intensity"));
        }
    }

    /** A minimal 3-spectrum run for the Phase 2 default-flip tests. */
    private static global.thalion.ttio.AcquisitionRun makeRun(
            global.thalion.ttio.Enums.AcquisitionMode mode,
            String ch1, String ch2) {
        int n = 3, p = 4;
        double[] a = new double[n * p];
        double[] b = new double[n * p];
        for (int i = 0; i < n * p; i++) {
            a[i] = 100.0 + 0.25 * i;
            b[i] = 1000.0 * (i + 1);
        }
        var idx = new global.thalion.ttio.SpectrumIndex(n,
                new long[]{0, 4, 8}, new int[]{4, 4, 4},
                new double[]{1, 2, 3}, new int[]{1, 1, 1},
                new int[]{1, 1, 1}, new double[]{0, 0, 0},
                new int[]{0, 0, 0}, new double[]{1, 1, 1});
        var channels = new java.util.LinkedHashMap<String, double[]>();
        channels.put(ch1, a);
        channels.put(ch2, b);
        var cfg = new global.thalion.ttio.InstrumentConfig("", "", "", "", "", "");
        return new global.thalion.ttio.AcquisitionRun("run_0001", mode, idx,
                cfg, channels, java.util.List.of(), java.util.List.of(),
                mode == global.thalion.ttio.Enums.AcquisitionMode.NMR_1D
                        ? "1H" : "", 0.0);
    }

    private static long compressionAttrOfMz(String path, String channel)
            throws Exception {
        try (var f = global.thalion.ttio.hdf5.Hdf5File.openReadOnly(path);
             var root = f.rootGroup();
             var study = root.openGroup("study");
             var msRuns = study.openGroup("ms_runs");
             var rg = msRuns.openGroup("run_0001");
             var sc = rg.openGroup("signal_channels");
             var ds = sc.openDataset(channel + "_values")) {
            if (!ds.hasAttribute("compression")) return -1L;
            return ds.readIntegerAttribute("compression", -1L);
        }
    }

    private static String writeTio(java.nio.file.Path dir,
            global.thalion.ttio.AcquisitionRun run) throws Exception {
        String path = dir.resolve("flip.tio").toString();
        global.thalion.ttio.SpectralDataset.create(path,
                "flip", "FDZ-P2", java.util.List.of(run),
                java.util.List.of(), java.util.List.of(),
                java.util.List.of()).close();
        return path;
    }

    @Test
    void msDefaultWritesCodec17(@org.junit.jupiter.api.io.TempDir java.nio.file.Path dir)
            throws Exception {
        var run = makeRun(global.thalion.ttio.Enums.AcquisitionMode.MS1_DDA,
                "mz", "intensity");
        String path = writeTio(dir, run);
        assertEquals(17L, compressionAttrOfMz(path, "mz"));
        assertEquals(17L, compressionAttrOfMz(path, "intensity"));
        try (var back = global.thalion.ttio.SpectralDataset.open(path)) {
            var r = back.msRuns().get("run_0001");
            assertNotNull(r);
            assertEquals(100.25, r.channels().get("mz")[1]);
        }
    }

    @Test
    void optDisableFloatDeltaPreservesZlib(
            @org.junit.jupiter.api.io.TempDir java.nio.file.Path dir)
            throws Exception {
        var run = makeRun(global.thalion.ttio.Enums.AcquisitionMode.MS1_DDA,
                "mz", "intensity");
        run.setOptDisableFloatDelta(true);
        String path = writeTio(dir, run);
        assertEquals(-1L, compressionAttrOfMz(path, "mz"),
                "opt-out must keep the chunked-zlib layout (no @compression)");
    }

    @Test
    void nmrDefaultUnchanged(@org.junit.jupiter.api.io.TempDir java.nio.file.Path dir)
            throws Exception {
        var run = makeRun(global.thalion.ttio.Enums.AcquisitionMode.NMR_1D,
                "chemical_shift", "intensity");
        String path = writeTio(dir, run);
        assertEquals(-1L, compressionAttrOfMz(path, "chemical_shift"),
                "NMR channels stay on the chunked-zlib layout");
    }

    @Test
    void goldenFixtureDecodes() throws Exception {
        byte[] stream;
        try (var in = getClass().getResourceAsStream(
                "/ttio/fixtures/float_delta_zstd_golden.bin")) {
            assertNotNull(in, "golden fixture missing from test resources");
            stream = in.readAllBytes();
        }
        assertBitExact(goldenValues(), FloatDeltaZstd.decode(stream));
    }
}
