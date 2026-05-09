/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import global.thalion.ttio.Enums.Precision;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-restoration unit tests for {@link Hdf5Dataset} branches that
 * the existing {@link global.thalion.ttio.Hdf5DatasetTest} round-trip
 * suite did not exercise. The pre-existing tests covered the primary
 * happy-path read/write for each precision; this file fills in:
 *
 * <ul>
 *   <li>The dataset-attribute API ({@link Hdf5Dataset#hasAttribute},
 *       {@link Hdf5Dataset#setStringAttribute},
 *       {@link Hdf5Dataset#readStringAttribute},
 *       {@link Hdf5Dataset#setUint8Attribute},
 *       {@link Hdf5Dataset#readIntegerAttribute},
 *       {@link Hdf5Dataset#deleteAttribute},
 *       {@link Hdf5Dataset#attributeNames}).</li>
 *   <li>Attribute-overwrite branches (the
 *       {@code if (H5Aexists) H5Adelete} path is only hit on the
 *       second write of the same attribute name).</li>
 *   <li>{@code readStringAttribute} returning {@code null} on
 *       missing-attribute and on non-string (uint8) attribute kinds.</li>
 *   <li>{@code readIntegerAttribute} reading both a 1-byte uint8
 *       attribute and a default-value-for-missing-attribute branch.</li>
 *   <li>The {@link Hdf5Dataset#readData(long, long)} hyperslab
 *       out-of-range exception branch and the
 *       {@code COMPLEX128} hyperslab branch.</li>
 *   <li>The {@code readData()} (full) {@code COMPLEX128} branch
 *       (round-trip already covered in {@link
 *       global.thalion.ttio.Hdf5DatasetTest#complex128RoundTrip} but
 *       at the dataset-level not all branches are reached when
 *       {@code length == 3}).</li>
 *   <li>{@link Hdf5Dataset#getDatasetId} accessor.</li>
 * </ul>
 *
 * <p>Per docs/superpowers/plans/2026-05-09-coverage-restoration.md J.5.</p>
 */
class Hdf5DatasetUnitTest {

    @TempDir
    Path tempDir;

    /** Create a tiny dataset (FLOAT64, length 4) and return both file
     *  + dataset for in-test attribute manipulation. The caller is
     *  responsible for closing both — test methods use try-with-
     *  resources so HDF5 handle leaks fail the JVM at exit. */
    private static record DsHandle(Hdf5File file, Hdf5Group root, Hdf5Dataset ds) {}

    private DsHandle openFresh(String fileName) {
        String path = tempDir.resolve(fileName).toString();
        Hdf5File f = Hdf5File.create(path);
        Hdf5Group root = f.rootGroup();
        Hdf5Dataset ds = root.createDataset("data", Precision.FLOAT64, 4, 0, 0);
        ds.writeData(new double[]{1.0, 2.0, 3.0, 4.0});
        return new DsHandle(f, root, ds);
    }

    // ── Dataset attribute lifecycle ─────────────────────────────────

    @Test
    @DisplayName("Hdf5Dataset: attribute lifecycle — set/read/exists/delete/names")
    void datasetAttributeLifecycle() {
        DsHandle h = openFresh("ds_attr_lifecycle.h5");
        try (Hdf5File f = h.file; Hdf5Group root = h.root; Hdf5Dataset ds = h.ds) {
            // Initial state: no attributes
            assertFalse(ds.hasAttribute("absent"));
            assertNull(ds.readStringAttribute("absent"),
                "missing string attr returns null");
            assertEquals(99L, ds.readIntegerAttribute("absent", 99L),
                "missing int attr returns default");
            assertEquals(List.of(), ds.attributeNames(),
                "fresh dataset has no attributes");

            // Write a string attribute, then read it back.
            ds.setStringAttribute("note", "hello world");
            assertTrue(ds.hasAttribute("note"));
            assertEquals("hello world", ds.readStringAttribute("note"));

            // Overwrite — exercises the (H5Aexists -> H5Adelete) branch
            // in setStringAttribute that only fires on the second write.
            ds.setStringAttribute("note", "second value");
            assertEquals("second value", ds.readStringAttribute("note"));

            // Write a uint8 attribute and read it back via the
            // size==1 branch in readIntegerAttribute.
            ds.setUint8Attribute("compression", 0xA5);
            assertEquals(0xA5L, ds.readIntegerAttribute("compression", -1L));
            // 0xA5 fits in uint8, so the masked value is preserved.

            // setUint8Attribute also has an overwrite branch.
            ds.setUint8Attribute("compression", 0x10);
            assertEquals(0x10L, ds.readIntegerAttribute("compression", -1L));

            // attributeNames should now report both.
            List<String> names = ds.attributeNames();
            assertEquals(2, names.size());
            assertTrue(names.contains("note"));
            assertTrue(names.contains("compression"));

            // readStringAttribute on a non-string-typed attr returns null.
            assertNull(ds.readStringAttribute("compression"),
                "uint8 attribute should return null from readStringAttribute");

            // Delete one attribute and confirm it's gone; the other survives.
            ds.deleteAttribute("note");
            assertFalse(ds.hasAttribute("note"));
            assertNull(ds.readStringAttribute("note"));
            assertTrue(ds.hasAttribute("compression"));

            // deleteAttribute on a now-absent name is a silent no-op
            // (the if (H5Aexists) guard means no exception is thrown).
            ds.deleteAttribute("note");
            assertFalse(ds.hasAttribute("note"));

            assertTrue(ds.getDatasetId() > 0,
                "getDatasetId returns the live HDF5 dataset id");
        }
    }

    // ── readStringAttribute fixed-length branch ─────────────────────

    @Test
    @DisplayName("Hdf5Dataset: readStringAttribute round-trips empty string")
    void datasetReadStringEmpty() {
        DsHandle h = openFresh("ds_string_empty.h5");
        try (Hdf5File f = h.file; Hdf5Group root = h.root; Hdf5Dataset ds = h.ds) {
            ds.setStringAttribute("desc", "");
            // VL_STRING null/empty branch.
            assertEquals("", ds.readStringAttribute("desc"));
        }
    }

    // ── readData(long, long) out-of-range + COMPLEX128 ──────────────

    @Test
    @DisplayName("Hdf5Dataset: readData(offset,count) rejects out-of-range slab")
    void datasetReadDataHyperslabOutOfRange() {
        DsHandle h = openFresh("ds_oor.h5");
        try (Hdf5File f = h.file; Hdf5Group root = h.root; Hdf5Dataset ds = h.ds) {
            // length is 4; offset+count exceeds it.
            Hdf5Errors.OutOfRangeException ex = assertThrows(
                Hdf5Errors.OutOfRangeException.class,
                () -> ds.readData(2, 5));
            assertNotNull(ex.getMessage(),
                "OutOfRangeException carries diagnostic context");
        }
    }

    @Test
    @DisplayName("Hdf5Dataset: COMPLEX128 hyperslab + full read both decode pairs")
    void datasetComplex128HyperslabAndFull() {
        String path = tempDir.resolve("ds_complex.h5").toString();
        // 4 complex numbers (8 doubles) — large enough to slab.
        double[] expected = {
            1.0,  2.0,
            3.0, -4.0,
            5.5,  6.5,
            7.25, 8.75
        };
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("fid",
                Precision.COMPLEX128, 4, 0, 0)) {
            ds.writeData(expected);
        }
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("fid")) {
            assertEquals(Precision.COMPLEX128, ds.getPrecision());
            assertEquals(4, ds.getLength());

            // Full read — exercises COMPLEX128 branch in readData().
            double[] full = (double[]) ds.readData();
            assertArrayEquals(expected, full, 1e-15);

            // Hyperslab read — exercises COMPLEX128 branch in
            // readData(offset, count). Take 2 complex numbers
            // starting at offset 1 → re/im at indices [2,3,4,5].
            double[] slab = (double[]) ds.readData(1, 2);
            assertEquals(4, slab.length, "2 complex numbers → 4 doubles");
            assertArrayEquals(
                new double[]{ 3.0, -4.0, 5.5, 6.5 },
                slab, 1e-15);
        }
    }

    // ── Persistence across close/reopen ─────────────────────────────

    @Test
    @DisplayName("Hdf5Dataset: attributes persist across file close/reopen")
    void datasetAttributePersistence() {
        String path = tempDir.resolve("ds_persist.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data",
                 Precision.FLOAT64, 2, 0, 0)) {
            ds.writeData(new double[]{1.5, 2.5});
            ds.setStringAttribute("note", "persisted");
            ds.setUint8Attribute("kind", 7);
        }
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            assertEquals("persisted", ds.readStringAttribute("note"));
            assertEquals(7L, ds.readIntegerAttribute("kind", -1L));
            // attributeNames() round-trip through a freshly opened file.
            List<String> names = ds.attributeNames();
            assertTrue(names.contains("note"));
            assertTrue(names.contains("kind"));
        }
    }
}
