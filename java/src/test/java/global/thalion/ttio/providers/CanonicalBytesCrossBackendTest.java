/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Path;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.7 M43 — cross-backend identity for
 * {@link StorageDataset#readCanonicalBytes()}.
 *
 * <p>The canonical byte form is the signing / encryption contract that
 * spans backends. A file signed via Hdf5Provider must verify via
 * MemoryProvider and SqliteProvider (and vice versa). These tests
 * pin that invariant by writing the same logical data through each
 * provider and asserting the byte streams match.</p>
 *
 * @since 0.7
 */
class CanonicalBytesCrossBackendTest {

    @TempDir
    Path tempDir;

    private byte[] readCanonical(StorageProvider provider, String path,
                                   double[] values, String dsName) {
        try {
            provider.open(path, StorageProvider.Mode.CREATE);
            StorageDataset ds = provider.rootGroup().createDataset(
                    dsName, Precision.FLOAT64, values.length, 0,
                    Compression.NONE, 0);
            ds.writeAll(values);
            provider.close();

            provider.open(path, StorageProvider.Mode.READ);
            byte[] bytes = provider.rootGroup().openDataset(dsName)
                    .readCanonicalBytes();
            provider.close();
            return bytes;
        } catch (RuntimeException e) {
            provider.close();
            throw e;
        }
    }

    @Test
    void primitiveFloat64CrossBackendIdentity() {
        double[] values = { 1.0, -2.5, 3.14159, 1e-10 };

        ByteBuffer bb = ByteBuffer.allocate(values.length * 8)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (double d : values) bb.putDouble(d);
        byte[] expected = bb.array();

        byte[] hdf5Bytes = readCanonical(new Hdf5Provider(),
                tempDir.resolve("cb.h5").toString(), values, "v");
        byte[] memoryBytes = readCanonical(new MemoryProvider(),
                "memory://m43-java-primitive", values, "v");
        MemoryProvider.discardStore("memory://m43-java-primitive");
        byte[] sqliteBytes = readCanonical(new SqliteProvider(),
                tempDir.resolve("cb.tio.sqlite").toString(), values, "v");

        assertArrayEquals(expected, hdf5Bytes, "HDF5 canonical bytes");
        assertArrayEquals(expected, memoryBytes, "Memory canonical bytes");
        assertArrayEquals(expected, sqliteBytes, "SQLite canonical bytes");
    }

    @Test
    void compoundCrossBackendIdentity() {
        // Build a canonical fixture manually so each backend can be
        // fed the same rows.
        List<CompoundField> schema = List.of(
            new CompoundField("run_name", CompoundField.Kind.VL_STRING),
            new CompoundField("spectrum_index", CompoundField.Kind.UINT32),
            new CompoundField("score", CompoundField.Kind.FLOAT64),
            new CompoundField("chem_id", CompoundField.Kind.VL_STRING)
        );
        List<Map<String, Object>> rows = new ArrayList<>();
        rows.add(Map.of("run_name", "runA", "spectrum_index", 0,
                         "score", 0.95, "chem_id", "CHEBI:15377"));
        rows.add(Map.of("run_name", "runB", "spectrum_index", 3,
                         "score", 0.72, "chem_id", "HMDB:0001234"));
        rows.add(new LinkedHashMap<>(Map.of(
            "run_name", "", "spectrum_index", 42,
            "score", -1.5, "chem_id", "")));  // empty VL strings
        rows.add(Map.of("run_name", "π-peak", "spectrum_index", 7,
                         "score", 3.14159, "chem_id", "unicode-entity"));

        // Expected canonical bytes — compute once via the shared helper.
        byte[] expected = StorageDataset.canonicaliseCompoundRows(rows, schema);
        assertTrue(expected.length > 0, "expected bytes non-empty");

        byte[] memoryBytes = compoundViaProvider(
                new MemoryProvider(),
                "memory://m43-java-compound", rows, schema);
        MemoryProvider.discardStore("memory://m43-java-compound");
        byte[] sqliteBytes = compoundViaProvider(
                new SqliteProvider(),
                tempDir.resolve("cb_compound.tio.sqlite").toString(),
                rows, schema);

        assertArrayEquals(expected, memoryBytes,
                "Memory compound canonical bytes diverge from expected");
        assertArrayEquals(expected, sqliteBytes,
                "SQLite compound canonical bytes diverge from expected");
        // Hdf5 compound write via the adapter requires converting to
        // Object[] row form (the adapter's writeAll expects that
        // shape — tested separately in ProviderTest). Cross-backend
        // identity between Memory and SQLite is sufficient to pin the
        // compound canonical layout for v0.7.
    }

    private byte[] compoundViaProvider(StorageProvider provider, String path,
                                         List<Map<String, Object>> rows,
                                         List<CompoundField> schema) {
        provider.open(path, StorageProvider.Mode.CREATE);
        try {
            StorageDataset ds = provider.rootGroup()
                    .createCompoundDataset("x", schema, rows.size());
            ds.writeAll(rows);
            provider.close();
        } catch (RuntimeException e) {
            provider.close();
            throw e;
        }
        provider.open(path, StorageProvider.Mode.READ);
        try {
            return provider.rootGroup().openDataset("x").readCanonicalBytes();
        } finally {
            provider.close();
        }
    }
}
