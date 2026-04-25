/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.exporters.JcampDxWriter;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.importers.JcampDxReader;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M73 acceptance: Raman / IR spectra + imaging cubes + JCAMP-DX
 * round-trip.
 */
class Milestone73Test {

    @TempDir
    Path tempDir;

    // ── Spectrum construction ───────────────────────────────────────

    @Test
    void ramanSpectrumConstructs() {
        double[] wn = {100.0, 200.0, 300.0};
        double[] it = {10.0, 20.0, 15.0};
        RamanSpectrum s = new RamanSpectrum(wn, it, 0, 1.23,
                785.0, 12.5, 0.5);
        assertArrayEquals(wn, s.wavenumberValues(), 0.0);
        assertArrayEquals(it, s.intensityValues(), 0.0);
        assertEquals(785.0, s.excitationWavelengthNm());
        assertEquals(12.5, s.laserPowerMw());
        assertEquals(0.5, s.integrationTimeSec());
    }

    @Test
    void irSpectrumConstructs() {
        double[] wn = {400.0, 800.0, 1600.0, 3200.0};
        double[] it = {0.1, 0.2, 0.4, 0.3};
        IRSpectrum s = new IRSpectrum(wn, it, 0, 0.0,
                IRMode.ABSORBANCE, 4.0, 64L);
        assertEquals(IRMode.ABSORBANCE, s.mode());
        assertEquals(4.0, s.resolutionCmInv());
        assertEquals(64L, s.numberOfScans());
    }

    // ── JCAMP-DX round-trip ─────────────────────────────────────────

    @Test
    void ramanJcampRoundTrip() throws IOException {
        int n = 256;
        double[] wn = new double[n];
        double[] it = new double[n];
        for (int i = 0; i < n; i++) {
            wn[i] = 100.0 + i * (3400.0 / (n - 1));
            it[i] = Math.abs(Math.sin(wn[i] / 137.0)) * 1000.0;
        }
        RamanSpectrum original = new RamanSpectrum(wn, it, 0, 0.0,
                785.0, 12.5, 0.5);
        Path p = tempDir.resolve("raman.jdx");
        JcampDxWriter.writeRamanSpectrum(original, p, "test Raman");
        Spectrum decoded = JcampDxReader.readSpectrum(p);
        assertInstanceOf(RamanSpectrum.class, decoded);
        RamanSpectrum r = (RamanSpectrum) decoded;
        assertEquals(n, r.wavenumberValues().length);
        assertEquals(785.0, r.excitationWavelengthNm(), 1e-9);
        assertEquals(12.5, r.laserPowerMw(), 1e-9);
        assertEquals(0.5, r.integrationTimeSec(), 1e-9);
        double[] ry = r.intensityValues();
        for (int i = 0; i < n; i++) {
            assertEquals(it[i], ry[i], Math.abs(it[i]) * 1e-9 + 1e-12);
        }
    }

    @Test
    void irJcampRoundTripAbsorbance() throws IOException {
        int n = 512;
        double[] wn = new double[n];
        double[] it = new double[n];
        for (int i = 0; i < n; i++) {
            wn[i] = 400.0 + i * (3600.0 / (n - 1));
            double z = (wn[i] - 1700.0) / 250.0;
            it[i] = Math.exp(-z * z);
        }
        IRSpectrum original = new IRSpectrum(wn, it, 0, 0.0,
                IRMode.ABSORBANCE, 4.0, 64L);
        Path p = tempDir.resolve("ir_abs.jdx");
        JcampDxWriter.writeIRSpectrum(original, p, "test IR abs");
        Spectrum decoded = JcampDxReader.readSpectrum(p);
        assertInstanceOf(IRSpectrum.class, decoded);
        IRSpectrum ir = (IRSpectrum) decoded;
        assertEquals(IRMode.ABSORBANCE, ir.mode());
        assertEquals(4.0, ir.resolutionCmInv(), 1e-9);
        assertEquals(64L, ir.numberOfScans());
        assertEquals(n, ir.wavenumberValues().length);
    }

    @Test
    void irJcampRoundTripTransmittance() throws IOException {
        double[] wn = {1000.0, 2000.0, 3000.0};
        double[] it = {0.9, 0.5, 0.95};
        IRSpectrum original = new IRSpectrum(wn, it, 0, 0.0,
                IRMode.TRANSMITTANCE, 8.0, 32L);
        Path p = tempDir.resolve("ir_tr.jdx");
        JcampDxWriter.writeIRSpectrum(original, p, "test IR tr");
        Spectrum decoded = JcampDxReader.readSpectrum(p);
        assertInstanceOf(IRSpectrum.class, decoded);
        assertEquals(IRMode.TRANSMITTANCE, ((IRSpectrum) decoded).mode());
    }

    @Test
    void jcampUnknownDataTypeThrows() throws IOException {
        Path p = tempDir.resolve("bogus.jdx");
        Files.writeString(p,
                "##TITLE=bogus\n##JCAMP-DX=5.01\n"
                + "##DATA TYPE=MASS SPECTRUM\n"
                + "##XYDATA=(X++(Y..Y))\n"
                + "1.0 2.0\n"
                + "##END=\n");
        assertThrows(IllegalArgumentException.class,
                () -> JcampDxReader.readSpectrum(p));
    }

    @Test
    void jcampEmptyXydataThrows() throws IOException {
        Path p = tempDir.resolve("empty.jdx");
        Files.writeString(p,
                "##TITLE=empty\n##JCAMP-DX=5.01\n"
                + "##DATA TYPE=RAMAN SPECTRUM\n"
                + "##XYDATA=(X++(Y..Y))\n"
                + "##END=\n");
        assertThrows(IllegalArgumentException.class,
                () -> JcampDxReader.readSpectrum(p));
    }

    // ── Imaging cube round-trip ─────────────────────────────────────

    @Test
    void ramanImageRoundTrip() {
        String path = tempDir.resolve("raman_image.tio").toString();

        int w = 8, h = 8, s = 32;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.25;
        double[] wn = new double[s];
        for (int i = 0; i < s; i++) wn[i] = 100.0 + i;

        RamanImage img = new RamanImage(w, h, s, 4,
                0.5, 0.5, "raster", 532.0, 5.0,
                cube, wn,
                "Raman map", "", java.util.List.of(), java.util.List.of(), java.util.List.of());

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(global.thalion.ttio.providers.Hdf5Provider.adapterForGroup(study));
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            RamanImage read = RamanImage.readFrom(
                    global.thalion.ttio.providers.Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertEquals(w, read.width());
            assertEquals(h, read.height());
            assertEquals(s, read.spectralPoints());
            assertEquals(532.0, read.excitationWavelengthNm(), 1e-10);
            assertEquals(5.0, read.laserPowerMw(), 1e-10);
            assertEquals("raster", read.scanPattern());
            assertArrayEquals(wn, read.wavenumbers(), 1e-12);
            assertArrayEquals(cube, read.intensityCube(), 1e-10);
        }
    }

    @Test
    void irImageRoundTrip() {
        String path = tempDir.resolve("ir_image.tio").toString();

        int w = 4, h = 4, s = 64;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) cube[i] = (i % 100) * 0.01;
        double[] wn = new double[s];
        for (int i = 0; i < s; i++) wn[i] = 400.0 + i * 10.0;

        IRImage img = new IRImage(w, h, s, 2,
                1.0, 1.0, "raster",
                IRMode.ABSORBANCE, 8.0,
                cube, wn,
                "IR map", "", java.util.List.of(), java.util.List.of(), java.util.List.of());

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(global.thalion.ttio.providers.Hdf5Provider.adapterForGroup(study));
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            IRImage read = IRImage.readFrom(
                    global.thalion.ttio.providers.Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertEquals(w, read.width());
            assertEquals(h, read.height());
            assertEquals(s, read.spectralPoints());
            assertEquals(IRMode.ABSORBANCE, read.mode());
            assertEquals(8.0, read.resolutionCmInv(), 1e-10);
            assertArrayEquals(wn, read.wavenumbers(), 1e-12);
            assertArrayEquals(cube, read.intensityCube(), 1e-10);
        }
    }
}
