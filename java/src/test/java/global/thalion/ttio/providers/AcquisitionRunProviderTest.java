/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.7 M44 — verify AcquisitionRun round-trips through the storage
 * protocol via the Hdf5Provider adapter, without any direct
 * {@code Hdf5Group} / {@code Hdf5Dataset} calls on the caller side.
 * Also confirms file-handle lifecycle: the underlying HDF5 file is
 * fully closeable after the run is materialised.
 */
public class AcquisitionRunProviderTest {

    @TempDir
    Path tempDir;

    private static AcquisitionRun sampleRun() {
        int nSpectra = 3;
        int pts = 4;
        long[] offsets = { 0, pts, 2L * pts };
        int[] lengths = { pts, pts, pts };
        double[] retTimes = { 1.0, 2.0, 3.0 };
        int[] msLevels = { 1, 1, 1 };
        int[] polarities = { 1, 1, 1 };
        double[] pmz = { 0, 0, 0 };
        int[] charges = { 0, 0, 0 };
        double[] basePeak = { 10, 20, 30 };

        SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths, retTimes,
                msLevels, polarities, pmz, charges, basePeak);

        double[] mz = { 100, 101, 102, 103, 100, 101, 102, 103, 100, 101, 102, 103 };
        double[] intensity = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

        return new AcquisitionRun("proto_run", AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("Vendor", "Model", null, null, null, null),
                Map.of("mz", mz, "intensity", intensity),
                List.of(), List.of(), null, 0.0);
    }

    @Test
    void roundTripViaHdf5Provider() {
        String path = tempDir.resolve("run_proto.tio").toString();
        AcquisitionRun original = sampleRun();

        // Write: wrap the raw Hdf5Group as a StorageGroup adapter.
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group ms = root.createGroup("ms_runs")) {
            StorageGroup parent = Hdf5Provider.adapterForGroup(ms);
            original.writeTo(parent);
        }

        // Read: same adapter path — no Hdf5Group/Hdf5Dataset leaks.
        AcquisitionRun read;
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group ms = root.openGroup("ms_runs")) {
            StorageGroup parent = Hdf5Provider.adapterForGroup(ms);
            read = AcquisitionRun.readFrom(parent, "proto_run");
        }

        assertNotNull(read);
        assertEquals("proto_run", read.name());
        assertEquals(3, read.count());
        assertEquals(AcquisitionMode.MS1_DDA, read.acquisitionMode());
        assertArrayEquals(original.channels().get("mz"),
                read.channels().get("mz"), 1e-12);
        assertArrayEquals(original.channels().get("intensity"),
                read.channels().get("intensity"), 1e-12);
    }

    @Test
    void fileHandleLifecycleReleaseable() {
        String path = tempDir.resolve("run_lifecycle.tio").toString();
        AcquisitionRun original = sampleRun();

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group ms = root.createGroup("ms_runs")) {
            original.writeTo(Hdf5Provider.adapterForGroup(ms));
        }

        // After all try-with-resources blocks exit, the file must be
        // fully closeable and re-openable — confirms the AcquisitionRun
        // path does not leave stray open HDF5 handles.
        AcquisitionRun read;
        Hdf5File f = Hdf5File.openReadOnly(path);
        try (Hdf5Group root = f.rootGroup();
             Hdf5Group ms = root.openGroup("ms_runs")) {
            read = AcquisitionRun.readFrom(
                    Hdf5Provider.adapterForGroup(ms), "proto_run");
        }
        // The file must close cleanly once the run is fully materialised;
        // stale open dataset/group handles would raise here.
        f.close();

        assertNotNull(read);
        assertEquals(3, read.count());
    }
}
