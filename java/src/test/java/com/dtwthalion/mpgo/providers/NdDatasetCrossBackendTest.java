/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

import com.dtwthalion.mpgo.Enums.Compression;
import com.dtwthalion.mpgo.Enums.Precision;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.7 M45 — cross-backend N-D (rank ≥ 2) dataset round-trip.
 *
 * <p>Proves that {@code createDatasetND} works identically on the HDF5,
 * Memory, and SQLite providers. Java reads return a flat primitive
 * array plus a shape metadata tuple (different from Python's
 * reshape-on-read convention, but element equality is preserved).</p>
 *
 * <p>MSImage cube writes still use the HDF5 native path pending M44.
 * M45's goal is to prove the provider protocol is ready to absorb
 * that refactor without silent correctness bugs.</p>
 *
 * @since 0.7
 */
class NdDatasetCrossBackendTest {

    @TempDir
    Path tempDir;

    /** Build a rank-3 cube shaped like a small MSImage. Element at
     *  (i,j,k) is {@code i*100 + j*10 + k + 0.5}. */
    private static double[] build3dFlatCube(long[] shape) {
        int n = (int) (shape[0] * shape[1] * shape[2]);
        double[] out = new double[n];
        int idx = 0;
        for (int i = 0; i < shape[0]; i++) {
            for (int j = 0; j < shape[1]; j++) {
                for (int k = 0; k < shape[2]; k++) {
                    out[idx++] = i * 100 + j * 10 + k + 0.5;
                }
            }
        }
        return out;
    }

    private static double[] roundtripCube(StorageProvider provider,
                                             String pathOrUrl,
                                             long[] shape,
                                             double[] flat) {
        provider.open(pathOrUrl, StorageProvider.Mode.CREATE);
        try {
            StorageDataset ds = provider.rootGroup().createDatasetND(
                    "cube", Precision.FLOAT64,
                    shape, null, Compression.NONE, 0);
            ds.writeAll(flat);
            assertArrayEquals(shape, ds.shape(),
                    "write-side shape preserved");
        } finally {
            provider.close();
        }
        provider.open(pathOrUrl, StorageProvider.Mode.READ);
        try {
            StorageDataset ds = provider.rootGroup().openDataset("cube");
            assertArrayEquals(shape, ds.shape(),
                    "read-side shape preserved");
            return (double[]) ds.readAll();
        } finally {
            provider.close();
        }
    }

    @Test
    void rank3CubeRoundtripHdf5() {
        long[] shape = { 4, 5, 6 };
        double[] expected = build3dFlatCube(shape);
        double[] got = roundtripCube(new Hdf5Provider(),
                tempDir.resolve("cube.h5").toString(), shape, expected);
        assertArrayEquals(expected, got);
    }

    @Test
    void rank3CubeRoundtripMemory() {
        long[] shape = { 4, 5, 6 };
        double[] expected = build3dFlatCube(shape);
        double[] got = roundtripCube(new MemoryProvider(),
                "memory://m45-java-rank3", shape, expected);
        assertArrayEquals(expected, got);
        MemoryProvider.discardStore("memory://m45-java-rank3");
    }

    @Test
    void rank3CubeRoundtripSqlite() {
        long[] shape = { 4, 5, 6 };
        double[] expected = build3dFlatCube(shape);
        double[] got = roundtripCube(new SqliteProvider(),
                tempDir.resolve("cube.mpgo.sqlite").toString(),
                shape, expected);
        assertArrayEquals(expected, got);
    }

    @Test
    void rank3CubeElementIdentityAcrossBackends() {
        long[] shape = { 4, 5, 6 };
        double[] expected = build3dFlatCube(shape);

        double[] hdf5 = roundtripCube(new Hdf5Provider(),
                tempDir.resolve("x.h5").toString(), shape, expected);
        double[] mem = roundtripCube(new MemoryProvider(),
                "memory://m45-java-xbackend", shape, expected);
        MemoryProvider.discardStore("memory://m45-java-xbackend");
        double[] sql = roundtripCube(new SqliteProvider(),
                tempDir.resolve("x.sqlite").toString(), shape, expected);

        assertArrayEquals(hdf5, mem, "HDF5 ↔ Memory");
        assertArrayEquals(mem, sql, "Memory ↔ SQLite");
        assertArrayEquals(hdf5, sql, "HDF5 ↔ SQLite");
    }

    @Test
    void rank2SlabRoundtripAllBackends() {
        long[] shape = { 4, 6 };
        int n = (int) (shape[0] * shape[1]);
        int[] expected = new int[n];
        for (int i = 0; i < n; i++) expected[i] = i;

        for (StorageProvider provider : new StorageProvider[]{
                new Hdf5Provider(), new MemoryProvider(),
                new SqliteProvider()}) {
            String key = provider.getClass().getSimpleName();
            String path = provider instanceof MemoryProvider
                    ? "memory://m45-java-rank2-" + key
                    : tempDir.resolve("slab_" + key).toString();

            provider.open(path, StorageProvider.Mode.CREATE);
            try {
                StorageDataset ds = provider.rootGroup().createDatasetND(
                        "slab", Precision.INT32,
                        shape, null, Compression.NONE, 0);
                ds.writeAll(expected);
            } finally {
                provider.close();
            }
            provider.open(path, StorageProvider.Mode.READ);
            try {
                int[] got = (int[]) provider.rootGroup()
                        .openDataset("slab").readAll();
                assertArrayEquals(expected, got,
                        key + " rank-2 int32 slab round-trip");
            } finally {
                provider.close();
                if (provider instanceof MemoryProvider) {
                    MemoryProvider.discardStore(path);
                }
            }
        }
    }

    @Test
    void capabilityQueriesMatchChunkSupport() {
        try (StorageProvider p = new Hdf5Provider()
                .open(tempDir.resolve("caps.h5").toString(),
                        StorageProvider.Mode.CREATE)) {
            assertTrue(p.supportsChunking());
            assertTrue(p.supportsCompression());
        }
        try (StorageProvider p = new MemoryProvider()
                .open("memory://m45-java-caps", StorageProvider.Mode.CREATE)) {
            assertFalse(p.supportsChunking());
            assertFalse(p.supportsCompression());
        }
        MemoryProvider.discardStore("memory://m45-java-caps");
        try (StorageProvider p = new SqliteProvider()
                .open(tempDir.resolve("caps.sqlite").toString(),
                        StorageProvider.Mode.CREATE)) {
            assertFalse(p.supportsChunking());
            assertFalse(p.supportsCompression());
        }
    }
}
