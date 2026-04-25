/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.ttio.importers;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dtwthalion.ttio.importers.BrukerTDFReader.BrukerTDFException;
import com.dtwthalion.ttio.importers.BrukerTDFReader.Metadata;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * v0.8 M53 — Java Bruker TDF reader (metadata side).
 *
 * <p>Binary-extraction round-trip is exercised by
 * {@code test_bruker_tdf.py::test_real_tdf_round_trip} on the Python
 * side; the Java wrapper just subprocesses into that helper for
 * binary data, so there is no separate Java binary-extraction
 * assertion.</p>
 */
public class BrukerTDFReaderTest {

    @Test
    public void metadataFromSyntheticFixture(@TempDir Path tmp) throws Exception {
        Path d = tmp.resolve("example.d");
        writeSyntheticTdf(d, /*frameCount=*/5, /*ms1Count=*/3,
                           "Bruker Daltonics", "timsTOF SCP");

        Metadata md = BrukerTDFReader.readMetadata(d);
        assertEquals(5, md.frameCount());
        assertEquals(3, md.ms1FrameCount());
        assertEquals(2, md.ms2FrameCount());
        assertEquals("Bruker Daltonics", md.instrumentVendor());
        assertEquals("timsTOF SCP", md.instrumentModel());
        assertTrue(md.retentionTimeMax() > md.retentionTimeMin());
        assertEquals("timsControl 4.0", md.acquisitionSoftware());
        assertEquals("NONE", md.properties().get("BeamSplitterConfig"));
    }

    @Test
    public void metadataRaisesOnMissingDirectory(@TempDir Path tmp) {
        assertThrows(BrukerTDFException.class,
                () -> BrukerTDFReader.readMetadata(tmp.resolve("nonexistent.d")));
    }

    @Test
    public void vendorDefaultsToBrukerWhenNoGlobalMetadata(@TempDir Path tmp)
            throws Exception {
        Path d = tmp.resolve("min.d");
        writeMinimalTdf(d);
        Metadata md = BrukerTDFReader.readMetadata(d);
        assertEquals("Bruker", md.instrumentVendor());
        assertEquals("", md.instrumentModel());
    }

    // ── Helpers ──────────────────────────────────────────────────

    private static void writeSyntheticTdf(Path dDir,
                                            int frameCount, int ms1Count,
                                            String vendor, String model)
            throws Exception {
        Files.createDirectories(dDir);
        Path tdf = dDir.resolve("analysis.tdf");
        try (Connection c = DriverManager.getConnection(
                    "jdbc:sqlite:" + tdf.toAbsolutePath());
             Statement st = c.createStatement()) {
            st.executeUpdate(
                "CREATE TABLE Frames ("
                + "Id INTEGER PRIMARY KEY, Time REAL NOT NULL, "
                + "MsMsType INTEGER NOT NULL)");
            st.executeUpdate(
                "CREATE TABLE GlobalMetadata (Key TEXT PRIMARY KEY, Value TEXT)");
            st.executeUpdate(
                "CREATE TABLE Properties (Key TEXT PRIMARY KEY, Value TEXT)");
            for (int i = 0; i < frameCount; i++) {
                int msms = i < ms1Count ? 0 : 9;
                double t = 0.5 * (i + 1);
                st.executeUpdate(String.format(
                    "INSERT INTO Frames (Id, Time, MsMsType) VALUES (%d, %f, %d)",
                    i + 1, t, msms));
            }
            st.executeUpdate("INSERT INTO GlobalMetadata (Key, Value) "
                    + "VALUES ('InstrumentVendor', '" + vendor + "')");
            st.executeUpdate("INSERT INTO GlobalMetadata (Key, Value) "
                    + "VALUES ('InstrumentName', '" + model + "')");
            st.executeUpdate("INSERT INTO GlobalMetadata (Key, Value) "
                    + "VALUES ('AcquisitionSoftware', 'timsControl 4.0')");
            st.executeUpdate("INSERT INTO Properties (Key, Value) "
                    + "VALUES ('MotorZ1', '-0.5')");
            st.executeUpdate("INSERT INTO Properties (Key, Value) "
                    + "VALUES ('BeamSplitterConfig', 'NONE')");
        }
    }

    private static void writeMinimalTdf(Path dDir) throws Exception {
        Files.createDirectories(dDir);
        Path tdf = dDir.resolve("analysis.tdf");
        try (Connection c = DriverManager.getConnection(
                    "jdbc:sqlite:" + tdf.toAbsolutePath());
             Statement st = c.createStatement()) {
            st.executeUpdate(
                "CREATE TABLE Frames ("
                + "Id INTEGER PRIMARY KEY, Time REAL NOT NULL, "
                + "MsMsType INTEGER NOT NULL)");
            st.executeUpdate(
                "INSERT INTO Frames (Id, Time, MsMsType) VALUES (1, 0.5, 0)");
        }
    }
}
