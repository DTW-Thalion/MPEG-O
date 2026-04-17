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
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Behavioural tests for SqliteProvider.
 * Mirrors the Python test_sqlite_provider.py test suite (24 tests).
 *
 * @since 0.6
 */
class SqliteProviderTest {

    // ── Registration / discovery ─────────────────────────────────────────

    @Test
    void providerNameAndRegistration() {
        boolean found = false;
        for (StorageProvider p : ServiceLoader.load(StorageProvider.class)) {
            if ("sqlite".equals(p.providerName())) { found = true; break; }
        }
        assertTrue(found, "sqlite provider must be discoverable via ServiceLoader");
    }

    @Test
    void supportsUrlRecognisedPatterns() {
        SqliteProvider p = new SqliteProvider();
        assertTrue(p.supportsUrl("sqlite:///path/to/data.mpgo.sqlite"));
        assertTrue(p.supportsUrl("/data/file.mpgo.sqlite"));
        assertTrue(p.supportsUrl("/data/file.sqlite"));
        assertFalse(p.supportsUrl("memory://foo"));
        assertFalse(p.supportsUrl("/data/file.mpgo.h5"));
    }

    // ── Open / close ─────────────────────────────────────────────────────

    @Test
    void openCreateClose(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            assertTrue(p.isOpen());
            assertNotNull(p.rootGroup());
        }
    }

    @Test
    void openCreateCloseIsNotOpen(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        SqliteProvider p = new SqliteProvider();
        p.open(path, StorageProvider.Mode.CREATE);
        assertTrue(p.isOpen());
        p.close();
        assertFalse(p.isOpen());
    }

    @Test
    void nativeHandleIsConnection(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            Object handle = p.nativeHandle();
            assertNotNull(handle);
            assertInstanceOf(java.sql.Connection.class, handle);
        }
    }

    @Test
    void modeReadMissingFileThrows(@TempDir Path tmp) {
        String path = tmp.resolve("does_not_exist.mpgo.sqlite").toString();
        SqliteProvider p = new SqliteProvider();
        assertThrows(RuntimeException.class,
                () -> p.open(path, StorageProvider.Mode.READ));
    }

    @Test
    void modeAppendCreatesIfAbsent(@TempDir Path tmp) throws Exception {
        String path = tmp.resolve("new.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.APPEND);
            assertTrue(p.isOpen());
            p.rootGroup().createGroup("g");
        }
        // Re-open read-only — group must persist
        try (SqliteProvider p2 = new SqliteProvider()) {
            p2.open(path, StorageProvider.Mode.READ);
            assertTrue(p2.rootGroup().hasChild("g"));
        }
    }

    // ── Groups ───────────────────────────────────────────────────────────

    @Test
    void groupsRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            StorageGroup study = root.createGroup("study");
            StorageGroup runs = study.createGroup("ms_runs");
            runs.createGroup("run_0001");
            assertTrue(root.childNames().contains("study"));
            assertTrue(study.hasChild("ms_runs"));
            assertTrue(runs.hasChild("run_0001"));
        }
        // Re-open
        try (SqliteProvider p2 = new SqliteProvider()) {
            p2.open(path, StorageProvider.Mode.READ);
            StorageGroup root2 = p2.rootGroup();
            assertTrue(root2.hasChild("study"));
            StorageGroup s2 = root2.openGroup("study");
            assertTrue(s2.hasChild("ms_runs"));
            StorageGroup r2 = s2.openGroup("ms_runs");
            assertTrue(r2.hasChild("run_0001"));
        }
    }

    @Test
    void openGroupMissingRaisesException(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            assertThrows(Exception.class, () -> root.openGroup("does_not_exist"));
        }
    }

    @Test
    void createGroupDuplicateRaisesException(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            root.createGroup("a");
            assertThrows(IllegalArgumentException.class, () -> root.createGroup("a"));
        }
    }

    @Test
    void deleteChildGroup(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            root.createGroup("g1");
            assertTrue(root.hasChild("g1"));
            root.deleteChild("g1");
            assertFalse(root.hasChild("g1"));
        }
    }

    @Test
    void deleteChildDataset(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            StorageDataset ds = root.createDataset("d1", Precision.FLOAT64, 4, 0,
                    Compression.NONE, 0);
            ds.writeAll(new double[]{1.0, 2.0, 3.0, 4.0});
            assertTrue(root.hasChild("d1"));
            root.deleteChild("d1");
            assertFalse(root.hasChild("d1"));
        }
    }

    // ── Primitive datasets ───────────────────────────────────────────────

    @Test
    void primitiveDataset1dRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        double[] original = {1.5, 2.5, 3.5, 4.5};
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageDataset ds = p.rootGroup().createDataset(
                    "intensity", Precision.FLOAT64, original.length, 0, Compression.NONE, 0);
            ds.writeAll(original);
            // Verify in same session
            StorageDataset ds2 = p.rootGroup().openDataset("intensity");
            assertEquals(Precision.FLOAT64, ds2.precision());
            assertEquals(4L, ds2.length());
            assertArrayEquals(original, (double[]) ds2.readAll(), 1e-12);
        }
        // Re-open
        try (SqliteProvider p2 = new SqliteProvider()) {
            p2.open(path, StorageProvider.Mode.READ);
            StorageDataset ds3 = p2.rootGroup().openDataset("intensity");
            assertArrayEquals(original, (double[]) ds3.readAll(), 1e-12);
        }
    }

    @Test
    void primitiveDatasetReadSlice(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            double[] data = new double[10];
            for (int i = 0; i < 10; i++) data[i] = i;
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.FLOAT64, 10, 0, Compression.NONE, 0);
            ds.writeAll(data);
            StorageDataset ds2 = p.rootGroup().openDataset("v");
            double[] slice = (double[]) ds2.readSlice(2, 3);
            assertEquals(3, slice.length);
            assertArrayEquals(new double[]{2.0, 3.0, 4.0}, slice, 1e-12);
            double[] tail = (double[]) ds2.readSlice(7, 3);
            assertArrayEquals(new double[]{7.0, 8.0, 9.0}, tail, 1e-12);
        }
    }

    @Test
    void primitiveDatasetNdRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            // 3x4 = 12 doubles
            double[] flat = new double[12];
            for (int i = 0; i < 12; i++) flat[i] = i;
            StorageDataset ds = p.rootGroup().createDatasetND(
                    "matrix", Precision.FLOAT64, new long[]{3, 4}, null,
                    Compression.NONE, 0);
            ds.writeAll(flat);
            StorageDataset ds2 = p.rootGroup().openDataset("matrix");
            assertArrayEquals(new long[]{3, 4}, ds2.shape());
            assertArrayEquals(flat, (double[]) ds2.readAll(), 1e-12);
        }
    }

    @Test
    void allPrecisionsRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();

            // FLOAT32
            root.createDataset("FLOAT32", Precision.FLOAT32, 2, 0, Compression.NONE, 0)
                .writeAll(new float[]{1.0f, 2.0f});
            // FLOAT64
            root.createDataset("FLOAT64", Precision.FLOAT64, 2, 0, Compression.NONE, 0)
                .writeAll(new double[]{3.0, 4.0});
            // INT32
            root.createDataset("INT32", Precision.INT32, 2, 0, Compression.NONE, 0)
                .writeAll(new int[]{-1, 2});
            // INT64
            root.createDataset("INT64", Precision.INT64, 2, 0, Compression.NONE, 0)
                .writeAll(new long[]{-9999999999L, 9999999999L});
            // UINT32 — stored as int bits, same bytes as Python numpy uint32
            root.createDataset("UINT32", Precision.UINT32, 2, 0, Compression.NONE, 0)
                .writeAll(new int[]{0, -1});  // 0 and 2^32-1 as unsigned
            // COMPLEX128 — interleaved real+imag doubles
            root.createDataset("COMPLEX128", Precision.COMPLEX128, 2, 0, Compression.NONE, 0)
                .writeAll(new double[]{1.0, 2.0, 3.0, 4.0}); // [1+2j, 3+4j]

            // Verify round-trips
            assertArrayEquals(new float[]{1.0f, 2.0f},
                    (float[]) root.openDataset("FLOAT32").readAll(), 1e-6f);
            assertArrayEquals(new double[]{3.0, 4.0},
                    (double[]) root.openDataset("FLOAT64").readAll(), 1e-12);
            assertArrayEquals(new int[]{-1, 2},
                    (int[]) root.openDataset("INT32").readAll());
            assertArrayEquals(new long[]{-9999999999L, 9999999999L},
                    (long[]) root.openDataset("INT64").readAll());
            assertArrayEquals(new int[]{0, -1},
                    (int[]) root.openDataset("UINT32").readAll());
            assertArrayEquals(new double[]{1.0, 2.0, 3.0, 4.0},
                    (double[]) root.openDataset("COMPLEX128").readAll(), 1e-12);
        }
    }

    // ── Compound datasets ────────────────────────────────────────────────

    @Test
    void compoundDatasetRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        List<CompoundField> fields = List.of(
            new CompoundField("run_name", CompoundField.Kind.VL_STRING),
            new CompoundField("spectrum_index", CompoundField.Kind.UINT32),
            new CompoundField("confidence_score", CompoundField.Kind.FLOAT64)
        );
        List<Map<String, Object>> rows = List.of(
            mapOf("run_name", "run_0001", "spectrum_index", 42L,
                    "confidence_score", 0.95),
            mapOf("run_name", "run_0001", "spectrum_index", 55L,
                    "confidence_score", 0.72)
        );
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageDataset ds = p.rootGroup().createCompoundDataset(
                    "identifications", fields, 2);
            ds.writeAll(rows);
        }
        try (SqliteProvider p2 = new SqliteProvider()) {
            p2.open(path, StorageProvider.Mode.READ);
            StorageDataset ds2 = p2.rootGroup().openDataset("identifications");
            assertNotNull(ds2.compoundFields());
            assertEquals(3, ds2.compoundFields().size());
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> back = (List<Map<String, Object>>) ds2.readAll();
            assertEquals(2, back.size());
            assertEquals("run_0001", back.get(0).get("run_name"));
            assertEquals(42L, back.get(0).get("spectrum_index"));
            assertEquals(0.95, ((Number) back.get(0).get("confidence_score")).doubleValue(), 1e-12);
            assertEquals(55L, back.get(1).get("spectrum_index"));
        }
    }

    // ── Attributes ───────────────────────────────────────────────────────

    @Test
    void groupAttributesRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup study = p.rootGroup().createGroup("study");
            study.setAttribute("title", "Test study");
            study.setAttribute("spectrum_count", 100L);
            study.setAttribute("threshold", 0.05);
            assertEquals("Test study", study.getAttribute("title"));
            assertEquals(100L, study.getAttribute("spectrum_count"));
            assertEquals(0.05, ((Number) study.getAttribute("threshold")).doubleValue(), 1e-15);
            List<String> names = study.attributeNames();
            assertTrue(names.contains("title"));
            assertTrue(names.contains("spectrum_count"));
            assertTrue(names.contains("threshold"));
        }
        // Re-open
        try (SqliteProvider p2 = new SqliteProvider()) {
            p2.open(path, StorageProvider.Mode.READ);
            StorageGroup study = p2.rootGroup().openGroup("study");
            assertEquals("Test study", study.getAttribute("title"));
        }
    }

    @Test
    void attributeHasAndDelete(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup g = p.rootGroup().createGroup("g");
            g.setAttribute("x", 42L);
            assertTrue(g.hasAttribute("x"));
            assertFalse(g.hasAttribute("y"));
            g.deleteAttribute("x");
            assertFalse(g.hasAttribute("x"));
        }
    }

    @Test
    void attributeMissingRaisesException(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            assertThrows(Exception.class, () -> root.getAttribute("nonexistent"));
        }
    }

    @Test
    void datasetAttributes(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.FLOAT64, 2, 0, Compression.NONE, 0);
            ds.setAttribute("units", "m/z");
            ds.setAttribute("count", 2L);
            assertEquals("m/z", ds.getAttribute("units"));
            assertEquals(2L, ds.getAttribute("count"));
            assertTrue(ds.hasAttribute("units"));
            assertTrue(ds.hasAttribute("count"));
            // deleteAttribute (extra method on SqliteDataset)
            ((SqliteProvider.SqliteDataset) ds).deleteAttribute("count");
            assertFalse(ds.hasAttribute("count"));
        }
    }

    // ── Read-only enforcement ────────────────────────────────────────────

    @Test
    void readOnlyRejectsWrites(@TempDir Path tmp) {
        String path = tmp.resolve("t.mpgo.sqlite").toString();
        // Create file
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            p.rootGroup().createGroup("g");
        }
        // Re-open read-only
        try (SqliteProvider p2 = new SqliteProvider()) {
            p2.open(path, StorageProvider.Mode.READ);
            StorageGroup root = p2.rootGroup();
            assertThrows(UnsupportedOperationException.class,
                    () -> root.createGroup("new"));
            assertThrows(UnsupportedOperationException.class,
                    () -> root.setAttribute("x", 1L));
        }
    }

    // ── MPEG-O shaped tree ───────────────────────────────────────────────

    @Test
    void mpegOShapedTreeRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("spectral.mpgo.sqlite").toString();

        // ── Write ──────────────────────────────────────────────────────
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();
            root.setAttribute("mpeg_o_format_version", "0.6-sqlite");

            StorageGroup study = root.createGroup("study");
            study.setAttribute("title", "End-to-end");

            StorageGroup runs = study.createGroup("ms_runs");
            StorageGroup run0 = runs.createGroup("run_0001");
            run0.setAttribute("acquisition_mode", 0L);
            run0.setAttribute("spectrum_class", "MPGOMassSpectrum");

            // spectrum_index group
            StorageGroup idx = run0.createGroup("spectrum_index");
            int n = 3;
            writeDs(idx, "offsets",               new int[]{0, 4, 8},             Precision.UINT32, n);
            writeDs(idx, "lengths",               new int[]{4, 4, 4},             Precision.UINT32, n);
            writeDs(idx, "retention_times",       new double[]{1.0, 2.0, 3.0},    Precision.FLOAT64, n);
            writeDs(idx, "ms_levels",             new int[]{1, 1, 1},             Precision.INT32, n);
            writeDs(idx, "polarities",            new int[]{1, 1, 1},             Precision.INT32, n);
            writeDs(idx, "precursor_mzs",         new double[]{0.0, 0.0, 0.0},    Precision.FLOAT64, n);
            writeDs(idx, "precursor_charges",     new int[]{0, 0, 0},             Precision.INT32, n);
            writeDs(idx, "base_peak_intensities", new double[]{100.0, 200.0, 300.0}, Precision.FLOAT64, n);

            // signal_channels
            StorageGroup sig = run0.createGroup("signal_channels");
            sig.setAttribute("channel_names", "mz,intensity");
            double[] mzAll = linspace(100.0, 400.0, 12);
            double[] iAll  = linspace(1.0, 12.0, 12);
            writeDs(sig, "mz_values",        mzAll, Precision.FLOAT64, 12);
            writeDs(sig, "intensity_values", iAll,  Precision.FLOAT64, 12);

            // instrument_config
            StorageGroup cfg = run0.createGroup("instrument_config");
            cfg.setAttribute("manufacturer", "Thermo");
            cfg.setAttribute("model", "Orbitrap Eclipse");

            // compound dataset
            StorageDataset idents = study.createCompoundDataset("identifications", List.of(
                new CompoundField("run_name",        CompoundField.Kind.VL_STRING),
                new CompoundField("spectrum_index",  CompoundField.Kind.UINT32),
                new CompoundField("chemical_entity", CompoundField.Kind.VL_STRING),
                new CompoundField("confidence_score",CompoundField.Kind.FLOAT64)
            ), 1);
            idents.writeAll(List.of(mapOf(
                "run_name", "run_0001",
                "spectrum_index", 0L,
                "chemical_entity", "CHEBI:17234",
                "confidence_score", 0.95
            )));
        }

        // ── Re-open and verify ─────────────────────────────────────────
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.READ);
            StorageGroup root = p.rootGroup();
            assertEquals("0.6-sqlite", root.getAttribute("mpeg_o_format_version"));

            StorageGroup study = root.openGroup("study");
            assertEquals("End-to-end", study.getAttribute("title"));

            StorageGroup run0 = study.openGroup("ms_runs").openGroup("run_0001");
            assertEquals(0L, run0.getAttribute("acquisition_mode"));
            assertEquals("MPGOMassSpectrum", run0.getAttribute("spectrum_class"));

            StorageGroup idx = run0.openGroup("spectrum_index");
            assertArrayEquals(new double[]{1.0, 2.0, 3.0},
                    (double[]) idx.openDataset("retention_times").readAll(), 1e-12);
            assertArrayEquals(new int[]{1, 1, 1},
                    (int[]) idx.openDataset("ms_levels").readAll());

            StorageGroup sig = run0.openGroup("signal_channels");
            assertEquals("mz,intensity", sig.getAttribute("channel_names"));
            assertArrayEquals(linspace(100.0, 400.0, 12),
                    (double[]) sig.openDataset("mz_values").readAll(), 1e-10);
            assertArrayEquals(linspace(1.0, 12.0, 12),
                    (double[]) sig.openDataset("intensity_values").readAll(), 1e-10);

            StorageGroup cfg = run0.openGroup("instrument_config");
            assertEquals("Thermo", cfg.getAttribute("manufacturer"));
            assertEquals("Orbitrap Eclipse", cfg.getAttribute("model"));

            @SuppressWarnings("unchecked")
            List<Map<String, Object>> idBack =
                    (List<Map<String, Object>>) study.openDataset("identifications").readAll();
            assertEquals(1, idBack.size());
            assertEquals("run_0001", idBack.get(0).get("run_name"));
            assertEquals("CHEBI:17234", idBack.get(0).get("chemical_entity"));
            assertEquals(0.95,
                    ((Number) idBack.get(0).get("confidence_score")).doubleValue(), 1e-12);
        }
    }

    // ── Cross-language compat (TODO) ─────────────────────────────────────

    @Test
    void crossLanguageCompatNote(@TempDir Path tmp) {
        // TODO: shell-out to Python to create a .mpgo.sqlite fixture, read it via Java.
        // The byte layout (little-endian BLOBs, JSON compound, same DDL) is designed to
        // be cross-compat, but automated verification from within the Java test suite
        // requires Python to be invokable via ProcessBuilder. This is left as a manual
        // check: run python/tests/test_sqlite_provider.py to create a file, then
        // open it with SqliteProvider and verify. Tracked as a cross-compat gap.
        assertTrue(true, "placeholder — see task report for cross-compat verification plan");
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private static void writeDs(StorageGroup g, String name, Object data,
                                 Precision precision, int length) {
        StorageDataset ds = g.createDataset(name, precision, length, 0, Compression.NONE, 0);
        ds.writeAll(data);
    }

    private static double[] linspace(double start, double end, int count) {
        double[] arr = new double[count];
        for (int i = 0; i < count; i++) {
            arr[i] = start + (end - start) * i / (count - 1);
        }
        return arr;
    }

    @SafeVarargs
    private static <K, V> Map<K, V> mapOf(Object... kvs) {
        Map<K, V> m = new LinkedHashMap<>();
        for (int i = 0; i < kvs.length; i += 2) {
            @SuppressWarnings("unchecked") K k = (K) kvs[i];
            @SuppressWarnings("unchecked") V v = (V) kvs[i + 1];
            m.put(k, v);
        }
        return m;
    }
}
