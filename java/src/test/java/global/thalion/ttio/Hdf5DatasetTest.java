/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.hdf5.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M31 acceptance criteria:
 * - float64 write + read back; values match within epsilon
 * - Chunked + zlib compressed int32 round-trip
 * - Complex128 compound type round-trip
 * - Partial read (hyperslab) verified
 */
class Hdf5DatasetTest {

    @TempDir
    Path tempDir;

    @Test
    void float64RoundTrip() {
        String path = tempDir.resolve("test_f64.h5").toString();
        double[] expected = { 1.0, 2.5, 3.14159, -0.001, 1e10, Double.MIN_VALUE };

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT64,
                     expected.length, 0, 0)) {
            ds.writeData(expected);
        }

        // Read back in a fresh file handle
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            assertEquals(Precision.FLOAT64, ds.getPrecision());
            assertEquals(expected.length, ds.getLength());

            double[] actual = (double[]) ds.readData();
            assertArrayEquals(expected, actual, 1e-15);
        }
    }

    @Test
    void float32RoundTrip() {
        String path = tempDir.resolve("test_f32.h5").toString();
        float[] expected = { 1.0f, 2.5f, 3.14f, -0.001f };

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT32,
                     expected.length, 0, 0)) {
            ds.writeData(expected);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            assertEquals(Precision.FLOAT32, ds.getPrecision());
            float[] actual = (float[]) ds.readData();
            assertArrayEquals(expected, actual, 1e-6f);
        }
    }

    @Test
    void chunkedZlibInt32RoundTrip() {
        String path = tempDir.resolve("test_zlib_i32.h5").toString();
        int[] expected = new int[1000];
        for (int i = 0; i < expected.length; i++) expected[i] = i * 7 - 500;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.INT32,
                     expected.length, 256, Compression.ZLIB, 6)) {
            ds.writeData(expected);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            assertEquals(Precision.INT32, ds.getPrecision());
            int[] actual = (int[]) ds.readData();
            assertArrayEquals(expected, actual);
        }
    }

    @Test
    void int64RoundTrip() {
        String path = tempDir.resolve("test_i64.h5").toString();
        long[] expected = { Long.MIN_VALUE, -1, 0, 1, Long.MAX_VALUE };

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.INT64,
                     expected.length, 0, 0)) {
            ds.writeData(expected);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            assertEquals(Precision.INT64, ds.getPrecision());
            long[] actual = (long[]) ds.readData();
            assertArrayEquals(expected, actual);
        }
    }

    @Test
    void complex128RoundTrip() {
        String path = tempDir.resolve("test_c128.h5").toString();
        // Interleaved re, im pairs: 3 complex numbers
        double[] expected = { 1.0, 2.0, 3.0, -4.0, 0.0, 0.5 };

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("fid", Precision.COMPLEX128,
                     3, 0, 0)) {
            ds.writeData(expected);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("fid")) {
            assertEquals(Precision.COMPLEX128, ds.getPrecision());
            assertEquals(3, ds.getLength());

            double[] actual = (double[]) ds.readData();
            assertArrayEquals(expected, actual, 1e-15);
        }
    }

    @Test
    void hyperslabPartialRead() {
        String path = tempDir.resolve("test_slab.h5").toString();
        double[] full = new double[100];
        for (int i = 0; i < full.length; i++) full[i] = i * 0.1;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT64,
                     full.length, 0, 0)) {
            ds.writeData(full);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            // Read elements [10..20)
            double[] slice = (double[]) ds.readData(10, 10);
            assertEquals(10, slice.length);
            for (int i = 0; i < 10; i++) {
                assertEquals((10 + i) * 0.1, slice[i], 1e-15,
                        "mismatch at offset " + i);
            }
        }
    }

    @Test
    void hyperslabOutOfRangeThrows() {
        String path = tempDir.resolve("test_oor.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT64, 10, 0, 0)) {
            ds.writeData(new double[10]);
            assertThrows(Hdf5Errors.OutOfRangeException.class,
                    () -> ds.readData(5, 10));
        }
    }

    @Test
    void uint32RoundTrip() {
        String path = tempDir.resolve("test_u32.h5").toString();
        // Java int[] treated as unsigned by HDF5
        int[] expected = { 0, 1, Integer.MAX_VALUE, -1 }; // -1 == 0xFFFFFFFF unsigned

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.UINT32,
                     expected.length, 0, 0)) {
            ds.writeData(expected);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            int[] actual = (int[]) ds.readData();
            assertArrayEquals(expected, actual);
        }
    }

    @Test
    void datasetInSubGroup() {
        String path = tempDir.resolve("test_nested.h5").toString();
        double[] expected = { 100.5, 200.5 };

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study");
             Hdf5Group runs = study.createGroup("ms_runs");
             Hdf5Group run1 = runs.createGroup("run_0001");
             Hdf5Dataset ds = run1.createDataset("mz_values", Precision.FLOAT64,
                     expected.length, 0, 0)) {
            ds.writeData(expected);
            run1.setStringAttribute("name", "run_0001");
            run1.setIntegerAttribute("spectrum_count", 2);
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group runs = study.openGroup("ms_runs");
             Hdf5Group run1 = runs.openGroup("run_0001");
             Hdf5Dataset ds = run1.openDataset("mz_values")) {
            double[] actual = (double[]) ds.readData();
            assertArrayEquals(expected, actual, 1e-15);
            assertEquals("run_0001", run1.readStringAttribute("name"));
            assertEquals(2, run1.readIntegerAttribute("spectrum_count", -1));
        }
    }
}
