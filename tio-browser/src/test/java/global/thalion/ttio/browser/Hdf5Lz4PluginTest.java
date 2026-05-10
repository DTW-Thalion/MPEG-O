/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;

import java.nio.file.Path;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import global.thalion.ttio.hdf5.Hdf5Dataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

/**
 * Confirms the bundled LZ4 plugin (filter id 32004) can decode a
 * dataset written with {@code Compression.LZ4}. Skips when natives
 * aren't bundled in this build (Phase D wires them).
 */
class Hdf5Lz4PluginTest {

    @Test
    void readsLz4CompressedDataset() {
        Assumptions.assumeTrue(
            Hdf5NativeLoader.class.getResourceAsStream(
                "/native/linux-x64/hdf5/libh5lz4.so") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/mac-aarch64/hdf5/libh5lz4.dylib") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/win-x64/hdf5/h5lz4.dll") != null,
            "no platform's HDF5 + LZ4 natives bundled in this build (Phase D wires it)");
        Hdf5NativeLoader.ensureLoaded();
        Path fixture = Path.of("src/test/resources/ttio/lz4_compressed.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(fixture.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            Hdf5Dataset ds = study.openDataset("lz4_payload");
            try {
                byte[] read = (byte[]) ds.readData();
                byte[] expected = new byte[Hdf5Lz4FixtureGenerator.PAYLOAD_LEN];
                for (int i = 0; i < expected.length; i++) {
                    expected[i] = (byte) (i & 0xff);
                }
                assertArrayEquals(expected, read);
            } finally {
                ds.close();
            }
        }
    }
}
