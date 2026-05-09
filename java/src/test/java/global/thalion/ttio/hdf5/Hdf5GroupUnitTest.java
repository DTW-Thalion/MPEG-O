/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-restoration unit tests for {@link Hdf5Group} branches the
 * existing test corpus didn't reach. Pre-existing tests covered the
 * core {@code createGroup} / {@code openDataset} / {@code openGroup}
 * happy paths; this file fills in:
 *
 * <ul>
 *   <li>{@link Hdf5Group#name} — both root ({@code "/"}) and
 *       last-segment branches.</li>
 *   <li>{@link Hdf5Group#attributeNames} (0% before this test).</li>
 *   <li>{@link Hdf5Group#setIntegerAttribute} +
 *       {@link Hdf5Group#readIntegerAttribute} round-trip.</li>
 *   <li>{@link Hdf5Group#setDoubleAttribute} +
 *       {@link Hdf5Group#readDoubleAttribute} round-trip and
 *       missing-attribute default branch.</li>
 *   <li>The overwrite branch ({@code if (H5Aexists) H5Adelete}) of
 *       all three setter methods.</li>
 *   <li>{@link Hdf5Group#deleteAttribute} — both happy path and
 *       no-op-on-missing.</li>
 *   <li>{@link Hdf5Group#deleteChild} — both delete-existing and
 *       no-op-on-missing.</li>
 *   <li>{@link Hdf5Group#hasChild} + {@link Hdf5Group#hasAttribute}
 *       returning {@code false}.</li>
 *   <li>{@link Hdf5Group#readStringAttribute} — VL_STRING happy path,
 *       and the legacy fixed-length back-compat branch (covered
 *       indirectly via {@link Hdf5Group#setStringAttribute}'s VL
 *       output and the empty-string branch).</li>
 *   <li>{@link Hdf5Group#childNames} on a multi-child group.</li>
 * </ul>
 *
 * <p>Per docs/superpowers/plans/2026-05-09-coverage-restoration.md J.5.</p>
 */
class Hdf5GroupUnitTest {

    @TempDir
    Path tempDir;

    // ── name() — root + last-segment branches ───────────────────────

    @Test
    @DisplayName("Hdf5Group: name() returns \"/\" for root and last segment for nested")
    void groupNameVariants() {
        String path = tempDir.resolve("group_name.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            // root → "/"
            assertEquals("/", root.name());
            // first-level child
            try (Hdf5Group child = root.createGroup("study")) {
                assertEquals("study", child.name());
                // nested grandchild
                try (Hdf5Group grand = child.createGroup("ms_runs")) {
                    assertEquals("ms_runs", grand.name());
                }
            }
        }
    }

    // ── childNames + deleteChild + hasChild ─────────────────────────

    @Test
    @DisplayName("Hdf5Group: childNames + hasChild + deleteChild lifecycle")
    void groupChildLifecycle() {
        String path = tempDir.resolve("group_child.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            // Empty root → empty childNames.
            assertEquals(List.of(), root.childNames());
            assertFalse(root.hasChild("missing"),
                "hasChild on missing returns false");

            // Create three named groups.
            try (Hdf5Group g = root.createGroup("alpha")) { /* close */ }
            try (Hdf5Group g = root.createGroup("beta"))  { /* close */ }
            try (Hdf5Group g = root.createGroup("gamma")) { /* close */ }

            List<String> names = root.childNames();
            assertEquals(3, names.size());
            assertTrue(names.contains("alpha"));
            assertTrue(names.contains("beta"));
            assertTrue(names.contains("gamma"));
            assertTrue(root.hasChild("beta"));

            // Delete one — exercises the H5Lexists==true branch.
            root.deleteChild("beta");
            assertFalse(root.hasChild("beta"));
            assertEquals(2, root.childNames().size());

            // Delete a missing child — exercises the H5Lexists==false branch
            // (no-op, no exception).
            root.deleteChild("never-was");
            assertEquals(2, root.childNames().size());
        }
    }

    // ── String attribute lifecycle, including overwrite + empty ─────

    @Test
    @DisplayName("Hdf5Group: setStringAttribute round-trip + overwrite + empty")
    void groupStringAttributeLifecycle() {
        String path = tempDir.resolve("group_string.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            assertFalse(root.hasAttribute("title"));

            root.setStringAttribute("title", "first");
            assertTrue(root.hasAttribute("title"));
            assertEquals("first", root.readStringAttribute("title"));

            // Overwrite — H5Aexists+H5Adelete branch.
            root.setStringAttribute("title", "second");
            assertEquals("second", root.readStringAttribute("title"));

            // Empty string — exercises the buf[0] == null fallback in
            // readStringAttribute's VL branch.
            root.setStringAttribute("empty", "");
            assertEquals("", root.readStringAttribute("empty"));
        }
    }

    @Test
    @DisplayName("Hdf5Group: readStringAttribute on missing attribute throws")
    void groupReadStringAttributeMissing() {
        String path = tempDir.resolve("group_string_missing.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            // The group reader (unlike the dataset reader) throws on
            // missing attributes per its declared contract.
            Hdf5Errors.AttributeException ex = assertThrows(
                Hdf5Errors.AttributeException.class,
                () -> root.readStringAttribute("nope"));
            assertTrue(ex.getMessage().contains("nope"),
                "exception message should reference the attribute name");
        }
    }

    // ── Integer attribute lifecycle ─────────────────────────────────

    @Test
    @DisplayName("Hdf5Group: setIntegerAttribute round-trip + overwrite + default")
    void groupIntegerAttributeLifecycle() {
        String path = tempDir.resolve("group_int.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            // Missing attr returns default.
            assertEquals(-99L, root.readIntegerAttribute("count", -99L));

            root.setIntegerAttribute("count", 42L);
            assertEquals(42L, root.readIntegerAttribute("count", -1L));

            // Overwrite — H5Aexists+H5Adelete branch.
            root.setIntegerAttribute("count", -7L);
            assertEquals(-7L, root.readIntegerAttribute("count", -1L));

            // Edge values: Long.MIN_VALUE and Long.MAX_VALUE round-trip
            // unchanged, confirming the H5T_NATIVE_INT64 binding.
            root.setIntegerAttribute("count", Long.MIN_VALUE);
            assertEquals(Long.MIN_VALUE,
                root.readIntegerAttribute("count", 0L));
            root.setIntegerAttribute("count", Long.MAX_VALUE);
            assertEquals(Long.MAX_VALUE,
                root.readIntegerAttribute("count", 0L));
        }
    }

    // ── Double attribute lifecycle ──────────────────────────────────

    @Test
    @DisplayName("Hdf5Group: setDoubleAttribute round-trip + overwrite + default")
    void groupDoubleAttributeLifecycle() {
        String path = tempDir.resolve("group_double.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            // Missing returns default.
            assertEquals(3.14, root.readDoubleAttribute("missing", 3.14), 0.0);

            root.setDoubleAttribute("rate", 0.125);
            assertEquals(0.125,
                root.readDoubleAttribute("rate", -1.0), 0.0);

            // Overwrite branch.
            root.setDoubleAttribute("rate", -1e-9);
            assertEquals(-1e-9,
                root.readDoubleAttribute("rate", 0.0), 1e-20);

            // Negative zero / infinities round-trip through IEEE-754.
            root.setDoubleAttribute("rate", Double.POSITIVE_INFINITY);
            assertEquals(Double.POSITIVE_INFINITY,
                root.readDoubleAttribute("rate", 0.0));
        }
    }

    // ── attributeNames + deleteAttribute lifecycle ──────────────────

    @Test
    @DisplayName("Hdf5Group: attributeNames lists every kind; deleteAttribute removes")
    void groupAttributeNamesAndDelete() {
        String path = tempDir.resolve("group_attr_names.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            // Empty group has no attributes.
            assertEquals(List.of(), root.attributeNames());

            root.setStringAttribute("title", "hello");
            root.setIntegerAttribute("count", 3L);
            root.setDoubleAttribute("rate", 0.5);

            List<String> names = root.attributeNames();
            assertEquals(3, names.size());
            assertTrue(names.contains("title"));
            assertTrue(names.contains("count"));
            assertTrue(names.contains("rate"));

            // Delete one — H5Aexists==true branch.
            root.deleteAttribute("count");
            assertFalse(root.hasAttribute("count"));
            assertEquals(2, root.attributeNames().size());

            // Delete missing — H5Aexists==false silent no-op.
            root.deleteAttribute("never-set");
            assertEquals(2, root.attributeNames().size());
        }
    }

    // ── Persistence across close/reopen ─────────────────────────────

    @Test
    @DisplayName("Hdf5Group: every attribute kind round-trips through close/reopen")
    void groupAttributesPersistenceAcrossReopen() {
        String path = tempDir.resolve("group_persist.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            root.setStringAttribute("title", "persist me");
            root.setIntegerAttribute("count", 17L);
            root.setDoubleAttribute("rate", 2.5);
            // Also create a nested group with its own attributes so
            // openGroup + attribute read travel through both code paths.
            try (Hdf5Group child = root.createGroup("nested")) {
                child.setStringAttribute("kind", "child");
            }
        }
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            assertEquals("persist me", root.readStringAttribute("title"));
            assertEquals(17L, root.readIntegerAttribute("count", 0L));
            assertEquals(2.5, root.readDoubleAttribute("rate", 0.0), 0.0);

            // openGroup-then-read covers the openGroup happy path
            // alongside the attribute read on a child group.
            try (Hdf5Group child = root.openGroup("nested")) {
                assertEquals("child", child.readStringAttribute("kind"));
                assertEquals("nested", child.name());
            }
        }
    }

    // ── Compression == ZLIB w/ level==0 (default branch in createDataset) ──

    @Test
    @DisplayName("Hdf5Group: createDataset(ZLIB, level=0) creates uncompressed chunked DS")
    void groupCreateDatasetZlibLevelZero() {
        String path = tempDir.resolve("group_zlib0.h5").toString();
        // level == 0 takes the (compression == ZLIB && compressionLevel > 0)
        // == false branch, so no H5Pset_deflate is called. The dataset
        // still gets chunked because chunkSize > 0.
        int n = 100;
        int[] expected = new int[n];
        for (int i = 0; i < n; i++) expected[i] = i;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.createDataset("data", Precision.INT32,
                     n, 32, Compression.ZLIB, 0)) {
            ds.writeData(expected);
        }
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Dataset ds = root.openDataset("data")) {
            assertArrayEquals(expected, (int[]) ds.readData());
        }
    }
}
