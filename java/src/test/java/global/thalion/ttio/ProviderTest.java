/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.providers.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Contract + round-trip tests for the storage provider abstraction —
 * Milestone 39 Part A/B/D. Parametrised across "hdf5" and "memory"
 * so every behavioural assertion runs through both paths.
 */
class ProviderTest {

    @TempDir
    Path tempDir;

    private String urlFor(String provider) {
        return switch (provider) {
            case "hdf5" -> tempDir.resolve("provider_" + System.nanoTime() + ".h5").toString();
            case "memory" -> "memory://test-" + System.nanoTime();
            case "sqlite" -> tempDir.resolve("provider_" + System.nanoTime() + ".sqlite").toString();
            case "zarr" -> tempDir.resolve("provider_" + System.nanoTime() + ".zarr").toString();
            default -> throw new IllegalArgumentException(provider);
        };
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory", "sqlite", "zarr"})
    void extendablePrimitiveAppendAndSlice(String provider) {
        String url = urlFor(provider);
        try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.CREATE, provider)) {
            StorageGroup root = p.rootGroup();
            try (StorageDataset ds = root.createDataset("blob", Precision.UINT8, 0, 4,
                    Compression.NONE, 0, true)) {
                assertTrue(ds.extendable());
                assertEquals(0, ds.length());
                ds.append(new byte[]{1, 2, 3});
                ds.append(new byte[]{4, 5, 6, 7, 8});
                ds.append(new byte[0]);
                assertEquals(8, ds.length());
                assertArrayEquals(new byte[]{3, 4, 5, 6}, (byte[]) ds.readSlice(2, 4));
                ds.writeSlice(1, new byte[]{9, 9});
                assertArrayEquals(new byte[]{1, 9, 9, 4, 5, 6, 7, 8}, (byte[]) ds.readAll());
            }
            try (StorageDataset ds = root.createDataset("vals", Precision.FLOAT64, 0, 2,
                    Compression.NONE, 0, true)) {
                ds.append(new double[]{1.5, 2.5, 3.5});
                assertEquals(3, ds.length());
                assertArrayEquals(new double[]{2.5, 3.5}, (double[]) ds.readSlice(1, 2), 0.0);
            }
            try (StorageDataset fixed = root.createDataset("fixed", Precision.UINT8, 2, 0,
                    Compression.NONE, 0)) {
                assertFalse(fixed.extendable());
                assertThrows(UnsupportedOperationException.class, () -> fixed.append(new byte[]{1}));
            }
            assertThrows(IllegalArgumentException.class, () -> root.createDataset("bad",
                    Precision.UINT8, 0, 0, Compression.NONE, 0, true));
        }
        try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.READ, provider)) {
            try (StorageDataset ds = p.rootGroup().openDataset("blob")) {
                assertTrue(ds.extendable());
                assertEquals(8, ds.length());
                assertArrayEquals(new byte[]{1, 9, 9, 4, 5, 6, 7, 8}, (byte[]) ds.readAll());
            }
        }
        if ("memory".equals(provider)) MemoryProvider.discardStore(url);
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory", "sqlite", "zarr"})
    void extendableCompoundWithUint64(String provider) {
        String url = urlFor(provider);
        List<CompoundField> fields = List.of(
            new CompoundField("start", CompoundField.Kind.UINT64),
            new CompoundField("n", CompoundField.Kind.UINT32),
            new CompoundField("score", CompoundField.Kind.FLOAT64));
        try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.CREATE, provider)) {
            try (StorageDataset ds = p.rootGroup().createCompoundDataset("idx", fields, 0, true, 2)) {
                assertTrue(ds.extendable());
                ds.append(java.util.Collections.singletonList(new Object[]{0L, 4, 0.5}));
                ds.append(java.util.Arrays.asList(new Object[]{4L, 1, 1.5}, new Object[]{5L, 2, 2.5}));
                assertEquals(3, ds.length());
                List<Map<String, Object>> rows = ds.readRows();
                assertEquals(3, rows.size());
                assertEquals(5L, ((Number) rows.get(2).get("start")).longValue());
                assertEquals(2, ((Number) rows.get(2).get("n")).intValue());
                assertEquals(2.5, ((Number) rows.get(2).get("score")).doubleValue(), 0.0);
            }
        }
        try (StorageProvider p = ProviderRegistry.open(url, StorageProvider.Mode.READ, provider)) {
            try (StorageDataset ds = p.rootGroup().openDataset("idx")) {
                assertEquals(3, ds.readRows().size());
                assertEquals(CompoundField.Kind.UINT64, ds.compoundFields().get(0).kind());
                byte[] canon = ds.readCanonicalBytes();
                assertEquals(3 * (8 + 4 + 8), canon.length);
            }
        }
        if ("memory".equals(provider)) MemoryProvider.discardStore(url);
    }

    @Test
    void discoverReturnsBothDefaultProviders() {
        Map<String, Class<? extends StorageProvider>> providers = ProviderRegistry.discover();
        assertTrue(providers.containsKey("hdf5"),
                "expected hdf5 in " + providers.keySet());
        assertTrue(providers.containsKey("memory"),
                "expected memory in " + providers.keySet());
    }

    @Test
    void hdf5ProviderSupportsFilePathsAndNotMemoryUrls() {
        StorageProvider h = new Hdf5Provider();
        assertTrue(h.supportsUrl("/tmp/file.h5"));
        assertTrue(h.supportsUrl("file:///tmp/file.h5"));
        assertFalse(h.supportsUrl("memory://x"));
    }

    @Test
    void memoryProviderSupportsOnlyMemoryUrls() {
        StorageProvider m = new MemoryProvider();
        assertTrue(m.supportsUrl("memory://x"));
        assertFalse(m.supportsUrl("/tmp/file.h5"));
    }

    @Test
    void registryOpensFileByPath() {
        String path = tempDir.resolve("registry.h5").toString();
        try (StorageProvider p = ProviderRegistry.open(path,
                StorageProvider.Mode.CREATE)) {
            assertEquals("hdf5", p.providerName());
            assertTrue(p.isOpen());
        }
    }

    @Test
    void registryOpensMemoryByScheme() {
        try (StorageProvider p = ProviderRegistry.open("memory://registry-test",
                StorageProvider.Mode.CREATE)) {
            assertEquals("memory", p.providerName());
        }
        MemoryProvider.discardStore("memory://registry-test");
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory"})
    void nestedGroupsAndAttributes(String provider) {
        String url = urlFor(provider);
        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.CREATE, provider)) {
            StorageGroup root = p.rootGroup();
            root.setAttribute("title", "round-trip");
            try (StorageGroup study = root.createGroup("study")) {
                study.setAttribute("version", 11L);
                try (StorageGroup runs = study.createGroup("ms_runs")) {
                    try (StorageGroup r1 = runs.createGroup("run_0001")) { }
                }
            }
        }

        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.READ, provider)) {
            StorageGroup root = p.rootGroup();
            Object title = root.getAttribute("title");
            if (title instanceof byte[] bytes) title = new String(bytes);
            assertEquals("round-trip", title.toString());
            assertTrue(root.hasChild("study"));
        }

        if ("memory".equals(provider)) {
            MemoryProvider.discardStore(url);
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory"})
    void primitiveDatasetRoundTrip(String provider) {
        String url = urlFor(provider);
        double[] expected = { 1.0, 2.5, 3.14, -0.001, 1e10 };

        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.CREATE, provider)) {
            StorageGroup root = p.rootGroup();
            try (StorageDataset ds = root.createDataset("values",
                    Precision.FLOAT64, expected.length, 0,
                    Compression.NONE, 0)) {
                ds.writeAll(expected);
                assertEquals(expected.length, ds.length());
                assertEquals(Precision.FLOAT64, ds.precision());
            }
        }

        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.READ, provider)) {
            try (StorageGroup root = p.rootGroup();
                 StorageDataset ds = root.openDataset("values")) {
                Object raw = ds.readAll();
                double[] got = (double[]) raw;
                assertArrayEquals(expected, got, 1e-15);
            }
        }

        if ("memory".equals(provider)) MemoryProvider.discardStore(url);
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory"})
    void compoundDatasetRoundTrip(String provider) {
        String url = urlFor(provider);
        List<CompoundField> fields = List.of(
                new CompoundField("run_name", CompoundField.Kind.VL_STRING),
                new CompoundField("spectrum_index", CompoundField.Kind.UINT32),
                new CompoundField("chemical_entity", CompoundField.Kind.VL_STRING),
                new CompoundField("confidence_score", CompoundField.Kind.FLOAT64));

        List<Object[]> rows = List.of(
                new Object[]{"run_A", 0, "CHEBI:15377", 0.95},
                new Object[]{"run_B", 3, "CHEBI:17234", 0.72});

        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.CREATE, provider)) {
            StorageGroup root = p.rootGroup();
            try (StorageDataset ds = root.createCompoundDataset(
                    "identifications", fields, rows.size())) {
                ds.writeAll(rows);
                assertEquals(rows.size(), ds.length());
                assertEquals(fields, ds.compoundFields());
            }
        }

        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.READ, provider)) {
            try (StorageGroup root = p.rootGroup();
                 StorageDataset ds = root.openDataset("identifications")) {
                @SuppressWarnings("unchecked")
                List<Object[]> got = (List<Object[]>) ds.readAll();
                assertEquals(2, got.size());
                // Primitive fields are faithfully recovered on both providers.
                assertEquals(0, (int) got.get(0)[1]);
                assertEquals(0.95, (double) got.get(0)[3], 1e-12);
                assertEquals(3, (int) got.get(1)[1]);
            }
        }

        if ("memory".equals(provider)) MemoryProvider.discardStore(url);
    }

    @Test
    void nativeHandleEscapeHatch() {
        // Hdf5Provider exposes an Hdf5File for byte-level code paths;
        // MemoryProvider returns null.
        String path = tempDir.resolve("native.h5").toString();
        try (StorageProvider p = ProviderRegistry.open(path,
                StorageProvider.Mode.CREATE)) {
            Object h = p.nativeHandle();
            assertNotNull(h, "hdf5 provider must expose a native handle");
            assertEquals("Hdf5File", h.getClass().getSimpleName());
        }
        String url = "memory://native-hatch";
        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.CREATE)) {
            assertNull(p.nativeHandle(),
                    "memory provider has no native handle");
        }
        MemoryProvider.discardStore(url);
    }

    @Test
    void memoryProviderSupportsNDDatasets() {
        String url = "memory://nd-test";
        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.CREATE)) {
            StorageDataset ds = p.rootGroup().createDatasetND(
                    "cube", Precision.FLOAT64,
                    new long[]{2, 3, 4}, new long[]{1, 3, 4},
                    Compression.NONE, 0);
            assertArrayEquals(new long[]{2, 3, 4}, ds.shape());
            assertArrayEquals(new long[]{1, 3, 4}, ds.chunks());
            // length() convenience returns first axis
            assertEquals(2, ds.length());
        }
        MemoryProvider.discardStore(url);
    }

    @ParameterizedTest
    @ValueSource(strings = {"hdf5", "memory"})
    void deleteAttribute(String provider) {
        String url = urlFor(provider);
        try (StorageProvider p = ProviderRegistry.open(url,
                StorageProvider.Mode.CREATE, provider)) {
            StorageGroup root = p.rootGroup();
            root.setAttribute("scratch", "x");
            assertTrue(root.hasAttribute("scratch"));
            root.deleteAttribute("scratch");
            assertFalse(root.hasAttribute("scratch"));
        }
        if ("memory".equals(provider)) MemoryProvider.discardStore(url);
    }
}
