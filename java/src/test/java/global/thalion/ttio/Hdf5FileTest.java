/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.hdf5.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M31 acceptance criteria: Hdf5File create/open/close; file exists on disk.
 * String and integer attributes on groups.
 */
class Hdf5FileTest {

    @TempDir
    Path tempDir;

    @Test
    void createAndOpenFile() {
        String path = tempDir.resolve("test_create.h5").toString();

        // Create
        try (Hdf5File f = Hdf5File.create(path)) {
            assertNotNull(f);
            assertTrue(new File(path).exists(), "file should exist on disk after create");
        }

        // Re-open read/write
        try (Hdf5File f = Hdf5File.open(path)) {
            assertNotNull(f);
            assertEquals(path, f.getPath());
        }

        // Re-open read-only
        try (Hdf5File f = Hdf5File.openReadOnly(path)) {
            assertNotNull(f);
        }
    }

    @Test
    void fileNotFoundThrows() {
        String bogus = tempDir.resolve("nonexistent.h5").toString();
        assertThrows(Hdf5Errors.FileNotFoundException.class, () -> Hdf5File.open(bogus));
        assertThrows(Hdf5Errors.FileNotFoundException.class, () -> Hdf5File.openReadOnly(bogus));
    }

    @Test
    void rootGroupAccessible() {
        String path = tempDir.resolve("test_root.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            assertNotNull(root);
            assertTrue(root.getGroupId() >= 0);
        }
    }

    @Test
    void createAndOpenSubGroups() {
        String path = tempDir.resolve("test_groups.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {

            try (Hdf5Group study = root.createGroup("study")) {
                assertNotNull(study);
                assertTrue(root.hasChild("study"));

                try (Hdf5Group msRuns = study.createGroup("ms_runs")) {
                    assertNotNull(msRuns);
                    assertTrue(study.hasChild("ms_runs"));
                }
            }

            assertFalse(root.hasChild("nonexistent"));
        }
    }

    @Test
    void stringAttributes() {
        String path = tempDir.resolve("test_str_attr.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {

            root.setStringAttribute("title", "Test Dataset");
            assertTrue(root.hasAttribute("title"));
            assertEquals("Test Dataset", root.readStringAttribute("title"));

            // Overwrite
            root.setStringAttribute("title", "Updated");
            assertEquals("Updated", root.readStringAttribute("title"));
        }
    }

    @Test
    void integerAttributes() {
        String path = tempDir.resolve("test_int_attr.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {

            root.setIntegerAttribute("count", 42);
            assertTrue(root.hasAttribute("count"));
            assertEquals(42, root.readIntegerAttribute("count", -1));

            // Missing attribute returns default
            assertEquals(-1, root.readIntegerAttribute("missing", -1));
        }
    }

    @Test
    void deleteChild() {
        String path = tempDir.resolve("test_delete.h5").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {

            try (Hdf5Group g = root.createGroup("temp")) {
                assertNotNull(g);
            }
            assertTrue(root.hasChild("temp"));

            root.deleteChild("temp");
            assertFalse(root.hasChild("temp"));

            // Delete of absent child is a no-op
            assertDoesNotThrow(() -> root.deleteChild("temp"));
        }
    }

    @Test
    void threadSafetyProbe() {
        String path = tempDir.resolve("test_ts.h5").toString();
        try (Hdf5File f = Hdf5File.create(path)) {
            // Just verify the probe doesn't crash — result depends on libhdf5 build
            boolean ts = f.isThreadSafe();
            // Lock/unlock cycle should succeed regardless
            f.lockForReading();
            f.unlockForReading();
            f.lockForWriting();
            f.unlockForWriting();
        }
    }
}
