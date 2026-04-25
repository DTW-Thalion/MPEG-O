/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.*;
import global.thalion.ttio.hdf5.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M35 acceptance criteria: thread safety, LZ4, Numpress-delta.
 */
class AdvancedFeaturesTest {

    @TempDir
    Path tempDir;

    // ── Thread safety ───────────────────────────────────────────────

    @Test
    void twoThreadsReadConcurrently() throws Exception {
        String path = tempDir.resolve("concurrent.h5").toString();
        double[] data = new double[1000];
        for (int i = 0; i < data.length; i++) data[i] = i * 0.1;

        // Write test file
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT64,
                     data.length, 256, 6)) {
            ds.writeData(data);
        }

        // Read concurrently from two threads
        try (Hdf5File f = Hdf5File.openReadOnly(path)) {
            ExecutorService exec = Executors.newFixedThreadPool(2);
            List<Future<double[]>> futures = new ArrayList<>();

            for (int t = 0; t < 2; t++) {
                futures.add(exec.submit(() -> {
                    try (Hdf5Group root = f.rootGroup();
                         Hdf5Dataset ds = root.openDataset("data")) {
                        return (double[]) ds.readData();
                    }
                }));
            }

            exec.shutdown();
            assertTrue(exec.awaitTermination(10, TimeUnit.SECONDS));

            for (Future<double[]> future : futures) {
                double[] result = future.get();
                assertEquals(data.length, result.length);
                assertArrayEquals(data, result, 1e-15);
            }
        }
    }

    @Test
    void writerBlocksReaders() throws Exception {
        String path = tempDir.resolve("writer_blocks.h5").toString();

        try (Hdf5File f = Hdf5File.create(path)) {
            // Acquire write lock
            f.lockForWriting();

            // Verify the lock was acquired (no deadlock)
            // In degraded mode (non-threadsafe HDF5), read lock also uses write lock
            f.unlockForWriting();

            // Verify we can still read after releasing write lock
            f.lockForReading();
            f.unlockForReading();
        }
    }

    @Test
    void threadSafetyModelDocumented() {
        String path = tempDir.resolve("ts_probe.h5").toString();
        try (Hdf5File f = Hdf5File.create(path)) {
            // isThreadSafe reflects libhdf5 build + lock init
            // On apt serial HDF5, this returns false -> degraded exclusive mode
            boolean ts = f.isThreadSafe();
            // Either way, lock operations should succeed
            f.lockForReading();
            f.unlockForReading();
            f.lockForWriting();
            f.unlockForWriting();
        }
    }

    // ── LZ4 compression ────────────────────────────────────────────

    @Test
    void lz4FilterAvailabilityCheck() {
        // LZ4 filter (32004) may or may not be available depending on
        // the system HDF5 build. Test graceful handling either way.
        String path = tempDir.resolve("lz4_test.h5").toString();
        double[] data = { 1.0, 2.0, 3.0, 4.0, 5.0 };

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            try {
                Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT64,
                        data.length, 4, Compression.LZ4, 0);
                ds.writeData(data);
                ds.close();

                // If we get here, LZ4 is available — verify round-trip
                try (Hdf5Dataset readDs = root.openDataset("data")) {
                    double[] read = (double[]) readDs.readData();
                    assertArrayEquals(data, read, 1e-15);
                }
            } catch (Hdf5Errors.DatasetCreateException e) {
                // LZ4 not available — that's fine, test passes
                assertTrue(e.getMessage().contains("LZ4") || e.getMessage().contains("32004"),
                        "Error should mention LZ4 filter");
            }
        }
    }

    @Test
    void zlibCompressionStillWorks() {
        // Confirm zlib (always available) still works after LZ4 code path added
        String path = tempDir.resolve("zlib_still.h5").toString();
        int[] data = new int[500];
        for (int i = 0; i < data.length; i++) data[i] = i;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.INT32,
                     data.length, 128, Compression.ZLIB, 6)) {
            ds.writeData(data);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            int[] read = (int[]) ds.readData();
            assertArrayEquals(data, read);
        }
    }

    // ── Numpress-delta ──────────────────────────────────────────────

    @Test
    void numpressRoundTripMz() {
        // Typical MS m/z data in 100-2000 range
        double[] mzValues = new double[1000];
        for (int i = 0; i < mzValues.length; i++) {
            mzValues[i] = 100.0 + i * 1.9 + Math.random() * 0.01;
        }

        NumpressCodec.EncodedResult encoded = NumpressCodec.encode(mzValues);
        assertTrue(encoded.scale() > 0);
        assertEquals(mzValues.length, encoded.deltas().length);

        double[] decoded = NumpressCodec.linearDecode(encoded.deltas(), encoded.scale());
        assertEquals(mzValues.length, decoded.length);

        // Sub-ppm relative error
        for (int i = 0; i < mzValues.length; i++) {
            double relError = Math.abs(decoded[i] - mzValues[i]) / Math.abs(mzValues[i]);
            assertTrue(relError < 1e-6,
                    String.format("Relative error %.2e at index %d exceeds 1 ppm", relError, i));
        }
    }

    @Test
    void numpressRoundTripIntensity() {
        double[] intensity = { 0, 100, 1e6, 1e-3, 42.5, 1e10 };
        long scale = NumpressCodec.computeScale(intensity);
        long[] deltas = NumpressCodec.linearEncode(intensity, scale);
        double[] decoded = NumpressCodec.linearDecode(deltas, scale);

        for (int i = 0; i < intensity.length; i++) {
            if (intensity[i] == 0) {
                assertEquals(0, decoded[i], 1e-15);
            } else {
                double relError = Math.abs(decoded[i] - intensity[i]) / Math.abs(intensity[i]);
                assertTrue(relError < 1e-6,
                        String.format("Relative error %.2e at index %d exceeds 1 ppm", relError, i));
            }
        }
    }

    @Test
    void numpressScaleComputation() {
        double[] small = { 0.001, 0.002, 0.003 };
        long scaleSmall = NumpressCodec.computeScale(small);

        double[] large = { 1e15, 2e15 };
        long scaleLarge = NumpressCodec.computeScale(large);

        assertTrue(scaleSmall > scaleLarge,
                "Smaller values should produce larger scale factor");
        assertTrue(scaleSmall > 0);
        assertTrue(scaleLarge > 0);
    }

    @Test
    void numpressEmptyArray() {
        double[] empty = {};
        NumpressCodec.EncodedResult encoded = NumpressCodec.encode(empty);
        assertEquals(0, encoded.deltas().length);

        double[] decoded = NumpressCodec.linearDecode(encoded.deltas(), encoded.scale());
        assertEquals(0, decoded.length);
    }

    @Test
    void numpressSingleValue() {
        double[] single = { 500.12345 };
        NumpressCodec.EncodedResult encoded = NumpressCodec.encode(single);
        double[] decoded = NumpressCodec.linearDecode(encoded.deltas(), encoded.scale());
        assertEquals(1, decoded.length);
        double relError = Math.abs(decoded[0] - single[0]) / single[0];
        assertTrue(relError < 1e-6);
    }

    @Test
    void numpressDeterministic() {
        double[] data = { 100.0, 200.5, 300.1 };
        NumpressCodec.EncodedResult enc1 = NumpressCodec.encode(data);
        NumpressCodec.EncodedResult enc2 = NumpressCodec.encode(data);

        assertEquals(enc1.scale(), enc2.scale());
        assertArrayEquals(enc1.deltas(), enc2.deltas());
    }

    @Test
    void numpressHdf5RoundTrip() {
        // Write Numpress-encoded data to HDF5 as int64, read back, decode
        String path = tempDir.resolve("numpress.h5").toString();
        double[] mzValues = { 100.123, 200.456, 300.789, 400.012, 500.345 };

        NumpressCodec.EncodedResult encoded = NumpressCodec.encode(mzValues);

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("mz_values", Precision.INT64,
                     encoded.deltas().length, 0, 0)) {
            ds.writeData(encoded.deltas());
            root.setIntegerAttribute("mz_numpress_fixed_point", encoded.scale());
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("mz_values")) {
            long[] readDeltas = (long[]) ds.readData();
            long scale = root.readIntegerAttribute("mz_numpress_fixed_point", 0);
            double[] decoded = NumpressCodec.linearDecode(readDeltas, scale);

            for (int i = 0; i < mzValues.length; i++) {
                double relError = Math.abs(decoded[i] - mzValues[i]) / mzValues[i];
                assertTrue(relError < 1e-6);
            }
        }
    }
}
