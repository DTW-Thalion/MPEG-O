/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.zip.GZIPOutputStream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Direct-API coverage tests for {@link ZarrProvider}.
 *
 * <p>This class supplements {@link ZarrProviderTest} (which covers
 * the happy-path round-trip invariants) with branch-targeted
 * exercises for: URL routing, all four open modes, re-open guard,
 * dataset / group lifecycle errors, every supported dtype,
 * gzip-decoder read path, slice reads, attribute lifecycle, and
 * compound-dataset openGroup rejection.</p>
 */
public class ZarrProviderUnitTest {

    // ── URL routing ─────────────────────────────────────────────────────

    @Test
    public void supportsUrlRecognisesZarrSchemeAndExtension() {
        ZarrProvider p = new ZarrProvider();
        assertTrue(p.supportsUrl("zarr:///abs/path"));
        assertTrue(p.supportsUrl("/some/where/data.zarr"));
        assertFalse(p.supportsUrl("/some/where/data.h5"));
        assertFalse(p.supportsUrl("hdf5://x"));
    }

    @Test
    public void pathForUrlStripsZarrSchemePrefix() {
        // bare path
        assertEquals("/tmp/x.zarr", ZarrProvider.pathForUrl("/tmp/x.zarr").toString().replace('\\', '/'));
        // zarr:/// triple-slash collapses
        Path triple = ZarrProvider.pathForUrl("zarr:///tmp/x.zarr");
        assertTrue(triple.toString().replace('\\', '/').endsWith("/tmp/x.zarr"));
    }

    @Test
    public void pathForUrlRejectsMemoryScheme() {
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.pathForUrl("zarr+memory://foo"));
    }

    @Test
    public void pathForUrlRejectsS3Scheme() {
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.pathForUrl("zarr+s3://bucket/key"));
    }

    // ── Open modes ─────────────────────────────────────────────────────

    @Test
    public void openCreateOverwritesExistingStore(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("create.zarr");
        // Stage an existing store with a child.
        try (ZarrProvider p = new ZarrProvider()) {
            p.open(store.toString(), StorageProvider.Mode.CREATE);
            p.rootGroup().createGroup("stale");
        }
        assertTrue(Files.exists(store.resolve("stale")));

        // Re-CREATE should wipe the previous contents.
        try (ZarrProvider p = new ZarrProvider()) {
            p.open(store.toString(), StorageProvider.Mode.CREATE);
            assertFalse(p.rootGroup().hasChild("stale"));
        }
    }

    @Test
    public void openReadFailsOnMissingStore(@TempDir Path tmp) {
        Path missing = tmp.resolve("nope.zarr");
        ZarrProvider p = new ZarrProvider();
        assertThrows(IllegalArgumentException.class,
                () -> p.open(missing.toString(), StorageProvider.Mode.READ));
    }

    @Test
    public void openReadWriteCreatesStoreIfMissing(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("rw.zarr");
        try (ZarrProvider p = new ZarrProvider()) {
            p.open(store.toString(), StorageProvider.Mode.READ_WRITE);
            assertTrue(p.isOpen());
            // Group meta got written.
            assertTrue(Files.exists(store.resolve("zarr.json")));
            p.rootGroup().createGroup("g1");
        }
    }

    @Test
    public void openAppendOpensExistingStore(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("append.zarr");
        try (ZarrProvider p = new ZarrProvider()) {
            p.open(store.toString(), StorageProvider.Mode.CREATE);
            p.rootGroup().createGroup("first");
        }
        try (ZarrProvider p = new ZarrProvider()) {
            p.open(store.toString(), StorageProvider.Mode.APPEND);
            assertTrue(p.rootGroup().hasChild("first"));
            p.rootGroup().createGroup("second");
        }
        assertTrue(Files.exists(store.resolve("second")));
    }

    @Test
    public void doubleOpenRejected(@TempDir Path tmp) {
        Path store = tmp.resolve("twice.zarr");
        ZarrProvider p = new ZarrProvider();
        p.open(store.toString(), StorageProvider.Mode.CREATE);
        try {
            assertThrows(IllegalStateException.class,
                    () -> p.open(store.toString(), StorageProvider.Mode.READ));
        } finally {
            p.close();
        }
    }

    @Test
    public void rootGroupAfterCloseRejected(@TempDir Path tmp) {
        Path store = tmp.resolve("closed.zarr");
        ZarrProvider p = new ZarrProvider();
        p.open(store.toString(), StorageProvider.Mode.CREATE);
        p.close();
        assertFalse(p.isOpen());
        assertThrows(IllegalStateException.class, p::rootGroup);
    }

    @Test
    public void capabilitiesAndNativeHandle(@TempDir Path tmp) {
        Path store = tmp.resolve("cap.zarr");
        try (ZarrProvider p = new ZarrProvider()) {
            p.open(store.toString(), StorageProvider.Mode.CREATE);
            assertTrue(p.supportsChunking());
            assertFalse(p.supportsCompression());
            // nativeHandle returns the on-disk root path.
            assertEquals(ZarrProvider.pathForUrl(store.toString()), p.nativeHandle());
        }
    }

    // ── Dtype coverage ─────────────────────────────────────────────────

    @Test
    public void roundTripFloat32(@TempDir Path tmp) {
        Path store = tmp.resolve("f32.zarr");
        float[] src = { 1.0f, -2.5f, 3.14f, 0.0f };
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.FLOAT32, src.length, 0, Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            assertEquals(Precision.FLOAT32, ds.precision());
            assertArrayEquals(src, (float[]) ds.readAll());
        }
    }

    @Test
    public void roundTripInt64(@TempDir Path tmp) {
        Path store = tmp.resolve("i64.zarr");
        long[] src = { 1L, -2L, Long.MAX_VALUE / 4, 0L };
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.INT64, src.length, 0, Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            assertArrayEquals(src, (long[]) ds.readAll());
        }
    }

    @Test
    public void roundTripUint32(@TempDir Path tmp) {
        Path store = tmp.resolve("u32.zarr");
        int[] src = { 1, 2, 3, 4, 5 };
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.UINT32, src.length, 0, Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            assertEquals(Precision.UINT32, ds.precision());
            assertArrayEquals(src, (int[]) ds.readAll());
        }
    }

    @Test
    public void roundTripUint16(@TempDir Path tmp) {
        Path store = tmp.resolve("u16.zarr");
        // We can't directly write short[] because writeAll doesn't accept it.
        // Instead, exercise UINT16 by ND createDataset + reading the raw chunk.
        // Verify dtype + bpe path via creation only.
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDatasetND(
                    "v", Precision.UINT16, new long[]{4}, new long[]{4},
                    Compression.NONE, 0);
            assertEquals(Precision.UINT16, ds.precision());
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            assertEquals(Precision.UINT16, ds.precision());
            // readAll on missing chunk → fill bytes → UINT16 unpacked
            short[] back = (short[]) ds.readAll();
            assertEquals(4, back.length);
            for (short s : back) assertEquals((short) 0, s);
        }
    }

    @Test
    public void roundTripUint8(@TempDir Path tmp) {
        Path store = tmp.resolve("u8.zarr");
        byte[] src = { 1, 2, 3, 4, 5, (byte) 0xFF };
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.UINT8, src.length, 0, Compression.NONE, 0);
            ds.writeAll(src);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            assertArrayEquals(src, (byte[]) ds.readAll());
        }
    }

    @Test
    public void uint64DtypeMapsToUint64String() {
        // dtypeFor handles UINT64 → "uint64" string. The reader symmetry
        // path (precisionFor) does not decode "uint64" today; that's a
        // known asymmetry tracked elsewhere.
        assertEquals("uint64", ZarrProvider.dtypeFor(Precision.UINT64));
    }

    @Test
    public void dtypeForRejectsReservedAndComplex() {
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.dtypeFor(Precision._RESERVED_INT8));
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.dtypeFor(Precision.COMPLEX128));
    }

    @Test
    public void precisionForAcceptsV2NumpyDtypes() {
        // v2 numpy-style canonical aliases (the non-default branches).
        assertEquals(Precision.FLOAT64, ZarrProvider.precisionFor("<f8"));
        assertEquals(Precision.FLOAT32, ZarrProvider.precisionFor("|f4"));
        assertEquals(Precision.INT64, ZarrProvider.precisionFor("<i8"));
        assertEquals(Precision.INT32, ZarrProvider.precisionFor("<i4"));
        assertEquals(Precision.UINT32, ZarrProvider.precisionFor("|u4"));
        assertEquals(Precision.UINT16, ZarrProvider.precisionFor("<u2"));
        assertEquals(Precision.UINT8, ZarrProvider.precisionFor("u1"));
    }

    @Test
    public void precisionForRejectsUnknownDtype() {
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.precisionFor("bogus_dtype"));
    }

    @Test
    public void bytesPerElementCoversAllSupported() {
        assertEquals(8, ZarrProvider.bytesPerElement(Precision.FLOAT64));
        assertEquals(8, ZarrProvider.bytesPerElement(Precision.INT64));
        assertEquals(8, ZarrProvider.bytesPerElement(Precision.UINT64));
        assertEquals(4, ZarrProvider.bytesPerElement(Precision.FLOAT32));
        assertEquals(4, ZarrProvider.bytesPerElement(Precision.INT32));
        assertEquals(4, ZarrProvider.bytesPerElement(Precision.UINT32));
        assertEquals(16, ZarrProvider.bytesPerElement(Precision.COMPLEX128));
        assertEquals(2, ZarrProvider.bytesPerElement(Precision.UINT16));
        assertEquals(1, ZarrProvider.bytesPerElement(Precision.UINT8));
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.bytesPerElement(Precision._RESERVED_INT8));
    }

    // ── Slice reads ────────────────────────────────────────────────────

    @Test
    public void readSliceReturnsCorrectSubsetForEachPrimitiveType(@TempDir Path tmp) {
        Path store = tmp.resolve("slice.zarr");
        double[] dsrc = { 0, 1, 2, 3, 4, 5, 6, 7 };
        float[] fsrc = { 10f, 11f, 12f, 13f };
        long[] lsrc = { 100L, 101L, 102L, 103L };
        int[] isrc = { 1000, 1001, 1002, 1003 };
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup g = p.rootGroup();
            g.createDataset("d", Precision.FLOAT64, dsrc.length, 0,
                    Compression.NONE, 0).writeAll(dsrc);
            g.createDataset("f", Precision.FLOAT32, fsrc.length, 0,
                    Compression.NONE, 0).writeAll(fsrc);
            g.createDataset("l", Precision.INT64, lsrc.length, 0,
                    Compression.NONE, 0).writeAll(lsrc);
            g.createDataset("i", Precision.INT32, isrc.length, 0,
                    Compression.NONE, 0).writeAll(isrc);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageGroup g = p.rootGroup();
            assertArrayEquals(new double[]{2, 3, 4},
                    (double[]) g.openDataset("d").readSlice(2, 3));
            assertArrayEquals(new float[]{11f, 12f},
                    (float[]) g.openDataset("f").readSlice(1, 2));
            assertArrayEquals(new long[]{101L, 102L},
                    (long[]) g.openDataset("l").readSlice(1, 2));
            assertArrayEquals(new int[]{1001, 1002},
                    (int[]) g.openDataset("i").readSlice(1, 2));
        }
    }

    // ── Group lifecycle ────────────────────────────────────────────────

    @Test
    public void childNamesListsGroupsAndDatasetsButNotDotPaths(@TempDir Path tmp)
            throws IOException {
        Path store = tmp.resolve("children.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createGroup("g1");
            root.createGroup("g2");
            root.createDataset("ds", Precision.FLOAT64, 4, 0,
                    Compression.NONE, 0);
            // Inject a hidden directory — should be filtered out.
            Files.createDirectories(store.resolve(".hidden"));
        }
        try (ZarrProvider p = openRead(store)) {
            List<String> names = p.rootGroup().childNames();
            assertTrue(names.contains("g1"));
            assertTrue(names.contains("g2"));
            assertTrue(names.contains("ds"));
            assertFalse(names.contains(".hidden"));
        }
    }

    @Test
    public void hasChildAndDeleteChild(@TempDir Path tmp) {
        Path store = tmp.resolve("delchild.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createGroup("victim");
            assertTrue(root.hasChild("victim"));
            assertFalse(root.hasChild("ghost"));
            root.deleteChild("victim");
            assertFalse(root.hasChild("victim"));
            // delete on missing is a no-op (deleteRecursive early-return).
            root.deleteChild("never-existed");
        }
    }

    @Test
    public void createGroupRejectsDuplicate(@TempDir Path tmp) {
        Path store = tmp.resolve("dup.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createGroup("once");
            assertThrows(IllegalArgumentException.class,
                    () -> root.createGroup("once"));
        }
    }

    @Test
    public void createDatasetRejectsDuplicate(@TempDir Path tmp) {
        Path store = tmp.resolve("dupds.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createDataset("once", Precision.FLOAT64, 4, 0,
                    Compression.NONE, 0);
            assertThrows(IllegalArgumentException.class,
                    () -> root.createDataset("once", Precision.FLOAT64, 4, 0,
                            Compression.NONE, 0));
        }
    }

    @Test
    public void createDatasetNDRejectsDuplicate(@TempDir Path tmp) {
        Path store = tmp.resolve("dupnd.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createDatasetND("once", Precision.FLOAT64, new long[]{4},
                    null, Compression.NONE, 0);
            assertThrows(IllegalArgumentException.class,
                    () -> root.createDatasetND("once", Precision.FLOAT64,
                            new long[]{4}, null, Compression.NONE, 0));
        }
    }

    @Test
    public void createCompoundRejectsDuplicate(@TempDir Path tmp) {
        Path store = tmp.resolve("dupcomp.zarr");
        List<CompoundField> schema = List.of(
                new CompoundField("k", CompoundField.Kind.UINT32));
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createCompoundDataset("once", schema, 0);
            assertThrows(IllegalArgumentException.class,
                    () -> root.createCompoundDataset("once", schema, 0));
        }
    }

    @Test
    public void createDatasetRejectsCompression(@TempDir Path tmp) {
        Path store = tmp.resolve("nogzip.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            assertThrows(UnsupportedOperationException.class,
                    () -> root.createDataset("v", Precision.FLOAT64, 4, 0,
                            Compression.ZLIB, 6));
            assertThrows(UnsupportedOperationException.class,
                    () -> root.createDatasetND("v", Precision.FLOAT64,
                            new long[]{4}, null, Compression.ZLIB, 6));
        }
    }

    @Test
    public void openGroupMissingThrows(@TempDir Path tmp) {
        Path store = tmp.resolve("missg.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            assertThrows(NoSuchElementException.class,
                    () -> root.openGroup("ghost"));
        }
    }

    @Test
    public void openGroupOnCompoundRejected(@TempDir Path tmp) {
        Path store = tmp.resolve("compg.zarr");
        List<CompoundField> schema = List.of(
                new CompoundField("k", CompoundField.Kind.UINT32));
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createCompoundDataset("comp", schema, 0);
            assertThrows(NoSuchElementException.class,
                    () -> root.openGroup("comp"));
        }
    }

    @Test
    public void openDatasetMissingThrows(@TempDir Path tmp) {
        Path store = tmp.resolve("missds.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            assertThrows(NoSuchElementException.class,
                    () -> root.openDataset("ghost"));
        }
    }

    @Test
    public void openDatasetOnPlainGroupThrows(@TempDir Path tmp) {
        Path store = tmp.resolve("groupasds.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.createGroup("g");
            assertThrows(NoSuchElementException.class,
                    () -> root.openDataset("g"));
        }
    }

    // ── Group attributes ───────────────────────────────────────────────

    @Test
    public void groupAttributeLifecycle(@TempDir Path tmp) {
        Path store = tmp.resolve("ga.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageGroup root = p.rootGroup();
            root.setAttribute("alpha", "A");
            root.setAttribute("beta", 1L);
            root.setAttribute("flag", Boolean.TRUE);
            root.setAttribute("ints", new int[]{1, 2, 3});
            root.setAttribute("longs", new long[]{4L, 5L});
            root.setAttribute("doubles", new double[]{0.5, 1.5});
            root.setAttribute("list", List.of("a", "b"));
            root.setAttribute("blob", "hi".getBytes());
            // _ttio_ prefix is reserved on group hasAttribute.
            assertTrue(root.hasAttribute("alpha"));
            assertFalse(root.hasAttribute("_ttio_kind"));
            // attributeNames excludes the reserved prefix entries.
            List<String> names = root.attributeNames();
            assertTrue(names.contains("alpha"));
            assertTrue(names.contains("beta"));
            // delete + delete-missing
            root.deleteAttribute("alpha");
            assertNull(root.getAttribute("alpha"));
            root.deleteAttribute("never-existed"); // no-op
        }
        try (ZarrProvider p = openRead(store)) {
            StorageGroup root = p.rootGroup();
            assertEquals("hi", root.getAttribute("blob"));
            assertEquals(Boolean.TRUE, root.getAttribute("flag"));
        }
    }

    // ── Dataset attributes ─────────────────────────────────────────────

    @Test
    public void datasetAttributeLifecycle(@TempDir Path tmp) {
        Path store = tmp.resolve("da.zarr");
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createDataset(
                    "v", Precision.FLOAT64, 4, 0, Compression.NONE, 0);
            ds.setAttribute("units", "ms");
            ds.setAttribute("scale", 0.5);
            assertTrue(ds.hasAttribute("units"));
            assertFalse(ds.hasAttribute("missing"));
            List<String> names = ds.attributeNames();
            assertTrue(names.contains("units"));
            assertTrue(names.contains("scale"));
            ds.deleteAttribute("units");
            assertFalse(ds.hasAttribute("units"));
            ds.deleteAttribute("never-existed"); // no-op branch
            assertNull(ds.getAttribute("missing"));
        }
    }

    @Test
    public void compoundDatasetAttributeLifecycleIgnoresReserved(@TempDir Path tmp) {
        Path store = tmp.resolve("ca.zarr");
        List<CompoundField> schema = List.of(
                new CompoundField("a", CompoundField.Kind.INT64),
                new CompoundField("b", CompoundField.Kind.FLOAT64),
                new CompoundField("c", CompoundField.Kind.VL_STRING));
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createCompoundDataset(
                    "comp", schema, 0);
            // The reserved schema/rows/count attributes are present but
            // hasAttribute("_ttio_*") must return false.
            assertFalse(ds.hasAttribute("_ttio_schema"));
            assertFalse(ds.hasAttribute("_ttio_rows"));
            assertFalse(ds.hasAttribute("_ttio_count"));
            ds.setAttribute("user", "joe");
            assertTrue(ds.hasAttribute("user"));
            assertEquals("joe", ds.getAttribute("user"));
            // attributeNames() filters reserved.
            List<String> names = ds.attributeNames();
            assertTrue(names.contains("user"));
            assertFalse(names.stream().anyMatch(n -> n.startsWith("_ttio_")));
            ds.deleteAttribute("user");
            assertFalse(ds.hasAttribute("user"));
            ds.deleteAttribute("never-existed"); // no-op
        }
    }

    // ── Compound dataset round-trip via Object[] rows ──────────────────

    @Test
    public void compoundDatasetAcceptsObjectArrayRows(@TempDir Path tmp) {
        Path store = tmp.resolve("compoa.zarr");
        List<CompoundField> schema = List.of(
                new CompoundField("ident", CompoundField.Kind.VL_STRING),
                new CompoundField("idx",   CompoundField.Kind.UINT32),
                new CompoundField("val",   CompoundField.Kind.FLOAT64));
        List<Object[]> arrayRows = new ArrayList<>();
        arrayRows.add(new Object[]{"x-1", 11L, 0.5});
        arrayRows.add(new Object[]{"x-2", 22L, 1.5});
        try (ZarrProvider p = openCreate(store)) {
            StorageDataset ds = p.rootGroup().createCompoundDataset(
                    "comp", schema, arrayRows.size());
            ds.writeAll(arrayRows);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("comp");
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> back =
                    (List<Map<String, Object>>) ds.readAll();
            assertEquals(2, back.size());
            assertEquals("x-1", back.get(0).get("ident"));
            assertEquals(11L, ((Number) back.get(0).get("idx")).longValue());
            assertEquals(0.5, ((Number) back.get(0).get("val")).doubleValue(), 1e-12);

            // readSlice on a compound dataset.
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> slice =
                    (List<Map<String, Object>>) ds.readSlice(1, 1);
            assertEquals(1, slice.size());
            assertEquals("x-2", slice.get(0).get("ident"));

            assertNull(ds.precision());
            assertEquals(2, ds.shape()[0]);
        }
    }

    @Test
    public void compoundDatasetVlBytesUnsupported() {
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.kindToString(CompoundField.Kind.VL_BYTES));
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.coerceCompoundField(new byte[]{1, 2},
                        CompoundField.Kind.VL_BYTES));
    }

    @Test
    public void schemaFromJsonRejectsUnknownKind() {
        assertThrows(IllegalArgumentException.class,
                () -> ZarrProvider.schemaFromJson(
                        "[{\"name\":\"x\",\"kind\":\"weird\"}]"));
    }

    @Test
    public void coerceCompoundFieldNullsCoerceToDefaults() {
        assertEquals("", ZarrProvider.coerceCompoundField(null,
                CompoundField.Kind.VL_STRING));
        assertEquals(0.0, ZarrProvider.coerceCompoundField(null,
                CompoundField.Kind.FLOAT64));
        assertEquals(0L, ZarrProvider.coerceCompoundField(null,
                CompoundField.Kind.INT64));
        assertEquals(0L, ZarrProvider.coerceCompoundField(null,
                CompoundField.Kind.UINT32));
        // bytes → utf-8 string
        assertEquals("hi", ZarrProvider.coerceCompoundField(
                "hi".getBytes(), CompoundField.Kind.VL_STRING));
    }

    // ── Codec / decompression ──────────────────────────────────────────

    @Test
    public void gzipChunkRoundTripReadsBack(@TempDir Path tmp) throws IOException {
        // Hand-craft a gzip-compressed chunk + matching zarr.json so the
        // read path's GZIP branch is exercised. (Write path does not yet
        // emit gzip, so we synthesise the store on disk.)
        Path store = tmp.resolve("gz.zarr");
        Files.createDirectories(store);
        Files.writeString(store.resolve("zarr.json"),
                "{\"zarr_format\":3,\"node_type\":\"group\",\"attributes\":{}}");

        // Float64 array of 4 elements, single chunk, gzip-compressed.
        Path arr = store.resolve("v");
        Files.createDirectories(arr);
        String arrMeta =
                "{\"zarr_format\":3,\"node_type\":\"array\","
              + "\"shape\":[4],\"data_type\":\"float64\","
              + "\"chunk_grid\":{\"name\":\"regular\","
              + "\"configuration\":{\"chunk_shape\":[4]}},"
              + "\"chunk_key_encoding\":{\"name\":\"default\","
              + "\"configuration\":{\"separator\":\"/\"}},"
              + "\"fill_value\":0,"
              + "\"codecs\":[{\"name\":\"bytes\",\"configuration\":{\"endian\":\"little\"}},"
              + "{\"name\":\"gzip\",\"configuration\":{\"level\":5}}],"
              + "\"attributes\":{}}";
        Files.writeString(arr.resolve("zarr.json"), arrMeta);

        // Encode 4 doubles {1, 2, 3, 4} little-endian, then gzip.
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocate(32)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN);
        bb.putDouble(1.0); bb.putDouble(2.0); bb.putDouble(3.0); bb.putDouble(4.0);
        ByteArrayOutputStream raw = new ByteArrayOutputStream();
        try (GZIPOutputStream gz = new GZIPOutputStream(raw)) {
            gz.write(bb.array());
        }
        Path chunkDir = arr.resolve("c");
        Files.createDirectories(chunkDir);
        Files.write(chunkDir.resolve("0"), raw.toByteArray());

        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("v");
            double[] back = (double[]) ds.readAll();
            assertArrayEquals(new double[]{1, 2, 3, 4}, back);
        }
    }

    @Test
    public void unsupportedCodecRejectedAtOpen(@TempDir Path tmp) throws IOException {
        Path store = tmp.resolve("badcodec.zarr");
        Files.createDirectories(store);
        Files.writeString(store.resolve("zarr.json"),
                "{\"zarr_format\":3,\"node_type\":\"group\",\"attributes\":{}}");
        Path arr = store.resolve("v");
        Files.createDirectories(arr);
        String arrMeta =
                "{\"zarr_format\":3,\"node_type\":\"array\","
              + "\"shape\":[4],\"data_type\":\"float64\","
              + "\"chunk_grid\":{\"name\":\"regular\","
              + "\"configuration\":{\"chunk_shape\":[4]}},"
              + "\"chunk_key_encoding\":{\"name\":\"default\","
              + "\"configuration\":{\"separator\":\"/\"}},"
              + "\"fill_value\":0,"
              + "\"codecs\":[{\"name\":\"bytes\",\"configuration\":{\"endian\":\"little\"}},"
              + "{\"name\":\"blosc\",\"configuration\":{}}],"
              + "\"attributes\":{}}";
        Files.writeString(arr.resolve("zarr.json"), arrMeta);

        try (ZarrProvider p = openRead(store)) {
            StorageGroup root = p.rootGroup();
            assertThrows(UnsupportedOperationException.class,
                    () -> root.openDataset("v"));
        }
    }

    @Test
    public void decompressChunkRejectsUnknownCodec() {
        Map<String, Object> spec = new LinkedHashMap<>();
        spec.put("name", "snappy");
        assertThrows(UnsupportedOperationException.class,
                () -> ZarrProvider.decompressChunk(spec, new byte[]{1, 2, 3}, 4));
    }

    @Test
    public void codecNameVariants() {
        assertNull(ZarrProvider.codecName(null));
        Map<String, Object> spec = new LinkedHashMap<>();
        spec.put("name", "gzip");
        assertEquals("gzip", ZarrProvider.codecName(spec));
        // map without "name" → toString
        Map<String, Object> nameless = new LinkedHashMap<>();
        assertNotNull(ZarrProvider.codecName(nameless));
        // non-map → toString
        assertEquals("plain", ZarrProvider.codecName("plain"));
    }

    @Test
    public void compressionCodecFromCodecsHandlesNullAndBytesOnly() {
        assertNull(ZarrProvider.compressionCodecFromCodecs(null, "x"));
        assertNull(ZarrProvider.compressionCodecFromCodecs(List.of(), "x"));
        Map<String, Object> bytesCodec = new LinkedHashMap<>();
        bytesCodec.put("name", "bytes");
        assertNull(ZarrProvider.compressionCodecFromCodecs(
                List.of(bytesCodec), "x"));
    }

    // ── Read-side metadata helpers ─────────────────────────────────────

    @Test
    public void isGroupDirAndIsArrayDirHandleMissingAndCorruptMeta(@TempDir Path tmp)
            throws IOException {
        // No zarr.json → not a group, not an array.
        assertFalse(ZarrProvider.isGroupDir(tmp));
        assertFalse(ZarrProvider.isArrayDir(tmp));

        // non-Map JSON → readMeta returns null → not a group/array.
        Path bogus = tmp.resolve("bogus");
        Files.createDirectories(bogus);
        Files.writeString(bogus.resolve("zarr.json"), "[1,2,3]");
        assertFalse(ZarrProvider.isGroupDir(bogus));
        assertFalse(ZarrProvider.isArrayDir(bogus));
    }

    @Test
    public void readZArrayThrowsOnMissingMeta(@TempDir Path tmp) throws IOException {
        Path empty = tmp.resolve("empty");
        Files.createDirectories(empty);
        assertThrows(IOException.class, () -> ZarrProvider.readZArray(empty));
    }

    @Test
    public void readZAttrsReturnsEmptyOnMissingOrNonMapAttributes(@TempDir Path tmp)
            throws IOException {
        // Missing zarr.json → empty map.
        assertTrue(ZarrProvider.readZAttrs(tmp).isEmpty());

        // attributes is a non-Map value → empty map.
        Path arr = tmp.resolve("oddattr");
        Files.createDirectories(arr);
        Files.writeString(arr.resolve("zarr.json"),
                "{\"zarr_format\":3,\"node_type\":\"group\",\"attributes\":\"not-a-map\"}");
        assertTrue(ZarrProvider.readZAttrs(arr).isEmpty());
    }

    @Test
    public void writeZAttrsNoOpsWhenNoMeta(@TempDir Path tmp) throws IOException {
        // Directory with no zarr.json: writeZAttrs early-returns without
        // throwing AND without creating the metadata file it would otherwise
        // write.
        Path nope = tmp.resolve("nope");
        ZarrProvider.writeZAttrs(nope, Map.of("k", "v"));
        assertFalse(Files.exists(nope.resolve("zarr.json")));
    }

    @Test
    public void readLongArrayRejectsNonList() {
        assertThrows(IllegalArgumentException.class,
                () -> ZarrProvider.readLongArray("not a list"));
    }

    // ── coerceForJson edge cases ───────────────────────────────────────

    @Test
    public void coerceForJsonCovers() {
        assertNull(ZarrProvider.coerceForJson(null));
        assertEquals(Boolean.TRUE, ZarrProvider.coerceForJson(true));
        assertEquals(42, ZarrProvider.coerceForJson(42));
        assertEquals("x", ZarrProvider.coerceForJson("x"));
        assertEquals("hi", ZarrProvider.coerceForJson("hi".getBytes()));

        Object longArr = ZarrProvider.coerceForJson(new long[]{1, 2});
        assertTrue(longArr instanceof List<?>);
        assertEquals(2, ((List<?>) longArr).size());

        Object intArr = ZarrProvider.coerceForJson(new int[]{1, 2});
        assertTrue(intArr instanceof List<?>);

        Object dblArr = ZarrProvider.coerceForJson(new double[]{1.0, 2.0});
        assertTrue(dblArr instanceof List<?>);

        Object listIn = List.of("a", "b");
        Object listOut = ZarrProvider.coerceForJson(listIn);
        assertTrue(listOut instanceof List<?>);
        assertEquals(2, ((List<?>) listOut).size());

        // Fallback toString() branch.
        Object weird = new Object() {
            @Override public String toString() { return "weird"; }
        };
        assertEquals("weird", ZarrProvider.coerceForJson(weird));
    }

    @Test
    public void jsonEscapeCovers() {
        // Direct call exercises the static helper's branches.
        String esc = ZarrProvider.jsonEscape("a\"b\\c\nd\re\tfg");
        assertTrue(esc.contains("\\\""));
        assertTrue(esc.contains("\\\\"));
        assertTrue(esc.contains("\\n"));
        assertTrue(esc.contains("\\r"));
        assertTrue(esc.contains("\\t"));
        assertTrue(esc.contains("\\u0001"));
    }

    // ── ND read with chunk-clipping (write-then-read) ──────────────────

    @Test
    public void chunkedNdShapeReadsBackMissingChunksAsFillZero(@TempDir Path tmp) {
        Path store = tmp.resolve("ndmiss.zarr");
        try (ZarrProvider p = openCreate(store)) {
            // Create an ND array but never write data → readAll returns
            // fill_value (0) for every chunk via the missing-chunk branch.
            StorageDataset ds = p.rootGroup().createDatasetND(
                    "g", Precision.INT32,
                    new long[]{4, 4}, new long[]{2, 2},
                    Compression.NONE, 0);
            assertEquals(2, ds.shape().length);
            assertEquals(2, ds.chunks().length);
        }
        try (ZarrProvider p = openRead(store)) {
            StorageDataset ds = p.rootGroup().openDataset("g");
            int[] back = (int[]) ds.readAll();
            assertEquals(16, back.length);
            for (int v : back) assertEquals(0, v);
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

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
