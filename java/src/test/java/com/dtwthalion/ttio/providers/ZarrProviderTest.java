/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.providers;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dtwthalion.ttio.Enums.Compression;
import com.dtwthalion.ttio.Enums.Precision;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Java ZarrProvider round-trip sanity tests (v3 layout).
 *
 * <p>Cross-language parity (Python / ObjC fixtures readable by Java
 * and vice versa) lives in a follow-up harness; this suite covers the
 * single-language round-trip invariants.</p>
 */
public class ZarrProviderTest {

    @Test
    public void openAndInspect(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("roundtrip.zarr");
        try (ZarrProvider p = openCreate(store)) {
            assertEquals("zarr", p.providerName());
            assertTrue(p.isOpen());
            assertTrue(p.supportsUrl(store.toString()));
            assertNotNull(p.rootGroup());
        }
        // zarr.json should have been written on CREATE.
        assertTrue(Files.exists(store.resolve("zarr.json")));
    }

    @Test
    public void roundTripFloat64OneDimArray(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("f64.zarr");
        double[] src = new double[100];
        for (int i = 0; i < src.length; i++) src[i] = i * 0.5;

        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            StorageDataset ds = root.createDataset(
                    "signal", Precision.FLOAT64, src.length, 0,
                    Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("signal");
            assertEquals(Precision.FLOAT64, ds.precision());
            assertArrayEquals(new long[]{100}, ds.shape());
            double[] back = (double[]) ds.readAll();
            assertArrayEquals(src, back);
        }
    }

    @Test
    public void roundTripInt32TwoDimArrayWithChunks(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("nd.zarr");
        long[] shape = { 4, 6 };
        long[] chunks = { 2, 3 };
        int[] src = new int[24];
        for (int i = 0; i < src.length; i++) src[i] = i * 7;

        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDatasetND(
                    "grid", Precision.INT32, shape, chunks,
                    Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("grid");
            assertArrayEquals(shape, ds.shape());
            assertArrayEquals(chunks, ds.chunks());
            int[] back = (int[]) ds.readAll();
            assertArrayEquals(src, back);
        }
    }

    @Test
    public void roundTripCompoundDataset(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("compound.zarr");
        List<CompoundField> schema = List.of(
            new CompoundField("ident_id",       CompoundField.Kind.VL_STRING),
            new CompoundField("spectrum_index", CompoundField.Kind.UINT32),
            new CompoundField("mass_error",     CompoundField.Kind.FLOAT64)
        );
        List<Map<String, Object>> rows = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("ident_id", "id-" + i);
            row.put("spectrum_index", (long) (100 + i));
            row.put("mass_error", 0.01 * i);
            rows.add(row);
        }
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createCompoundDataset(
                    "identifications", schema, rows.size());
            ds.writeAll(rows);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("identifications");
            assertEquals(schema.size(), ds.compoundFields().size());
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> back = (List<Map<String, Object>>) ds.readAll();
            assertEquals(rows.size(), back.size());
            for (int i = 0; i < rows.size(); i++) {
                assertEquals(rows.get(i).get("ident_id"),
                             back.get(i).get("ident_id"));
                assertEquals(((Number) rows.get(i).get("spectrum_index")).longValue(),
                             ((Number) back.get(i).get("spectrum_index")).longValue());
                assertEquals((double) rows.get(i).get("mass_error"),
                             ((Number) back.get(i).get("mass_error")).doubleValue(),
                             1e-12);
            }
        }
    }

    @Test
    public void groupAttributesRoundTrip(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("attrs.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.setAttribute("title", "demo");
            root.setAttribute("count", 42L);
            StorageGroup child = root.createGroup("sub");
            child.setAttribute("note", "nested");
        }
        try (ZarrProvider p = openRead(store)) {
            StorageGroup root = p.rootGroup();
            assertEquals("demo", root.getAttribute("title"));
            assertEquals(42L, ((Number) root.getAttribute("count")).longValue());
            StorageGroup child = root.openGroup("sub");
            assertEquals("nested", child.getAttribute("note"));
        }
    }

    @Test
    public void canonicalBytesMatchHdf5LayoutForFloat64(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("canon.zarr");
        double[] src = { 1.0, 2.0, 3.5, -0.25 };
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.FLOAT64, src.length, 0,
                    Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            byte[] canonical = ds.readCanonicalBytes();
            // 4 float64 values little-endian = 32 bytes.
            assertEquals(32, canonical.length);
            // First value 1.0 little-endian = 00 00 00 00 00 00 F0 3F
            assertEquals((byte) 0x00, canonical[0]);
            assertEquals((byte) 0xF0, canonical[6]);
            assertEquals((byte) 0x3F, canonical[7]);
        }
    }

    @Test
    public void providerRegistryDiscoversZarr() {
        Map<String, Class<? extends StorageProvider>> reg =
                ProviderRegistry.discover();
        assertTrue(reg.containsKey("zarr"),
                "ProviderRegistry must discover the zarr provider");
        assertEquals(ZarrProvider.class, reg.get("zarr"));
    }

    // ── Helpers ──

    private static ZarrProvider openCreate(Path p) {
        ZarrProvider zp = new ZarrProvider();
        zp.open(p.toString(), StorageProvider.Mode.CREATE);
        return zp;
    }

    private static ZarrProvider openRead(Path p) {
        ZarrProvider zp = new ZarrProvider();
        zp.open(p.toString(), StorageProvider.Mode.READ);
        return zp;
    }
}
