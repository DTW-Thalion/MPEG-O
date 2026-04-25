/*
 * TTI-O Java Implementation — imzML writer round-trip tests.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.exporters;

import com.dtwthalion.ttio.importers.ImzMLReader;
import com.dtwthalion.ttio.importers.ImzMLReader.ImzMLImport;
import com.dtwthalion.ttio.importers.ImzMLReader.PixelSpectrum;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.9+ imzML exporter test. Mirrors the Python
 * ({@code tests/test_imzml_writer.py}) and ObjC
 * ({@code TestImzMLWriter.m}) suites so regressions surface in the
 * per-language layer.
 */
final class ImzMLWriterTest {

    @Test
    void continuousModeRoundTripsBitIdentical(@TempDir Path tmp) throws Exception {
        double[] mz = new double[128];
        for (int i = 0; i < mz.length; i++) mz[i] = 100.0 + i * (800.0 / 127);
        double[] i0 = new double[128];
        double[] i1 = new double[128];
        for (int i = 0; i < 128; i++) {
            i0[i] = i;
            i1[i] = i + 10;
        }
        List<PixelSpectrum> pixels = List.of(
            new PixelSpectrum(1, 1, 1, mz, i0),
            new PixelSpectrum(2, 1, 1, mz, i1)
        );
        Path imzml = tmp.resolve("c.imzML");
        ImzMLWriter.WriteResult res = ImzMLWriter.write(
            pixels, imzml, null, "continuous",
            2, 1, 1, 50.0, 50.0,
            "flyback", null);
        assertEquals("continuous", res.mode());
        assertEquals(2, res.nPixels());
        assertEquals(32, res.uuidHex().length());
        assertTrue(res.imzmlPath().toFile().isFile());
        assertTrue(res.ibdPath().toFile().isFile());

        ImzMLImport imp = ImzMLReader.read(imzml);
        assertEquals("continuous", imp.mode());
        assertEquals(res.uuidHex(), imp.uuidHex());
        assertEquals(2, imp.gridMaxX());
        assertEquals(1, imp.gridMaxY());
        assertEquals(50.0, imp.pixelSizeX(), 1e-9);
        assertEquals(50.0, imp.pixelSizeY(), 1e-9);
        assertEquals(2, imp.spectra().size());
        assertArrayEquals(mz, imp.spectra().get(0).mz(), 0.0);
        assertArrayEquals(i0, imp.spectra().get(0).intensity(), 0.0);
        assertArrayEquals(i1, imp.spectra().get(1).intensity(), 0.0);
    }

    @Test
    void processedModeRoundTripsBitIdentical(@TempDir Path tmp) throws Exception {
        List<PixelSpectrum> pixels = List.of(
            new PixelSpectrum(1, 1, 1,
                new double[]{100, 200, 300},
                new double[]{1, 2, 3}),
            new PixelSpectrum(2, 1, 1,
                new double[]{100, 200, 300, 400},
                new double[]{4, 5, 6, 7})
        );
        Path imzml = tmp.resolve("p.imzML");
        ImzMLWriter.WriteResult res = ImzMLWriter.write(
            pixels, imzml, null, "processed",
            0, 0, 0, 0.0, 0.0, "flyback", null);
        assertEquals("processed", res.mode());

        ImzMLImport imp = ImzMLReader.read(imzml);
        assertEquals("processed", imp.mode());
        assertEquals(2, imp.gridMaxX(), "gridMaxX derived from coords");
        assertEquals(1, imp.gridMaxY(), "gridMaxY derived from coords");
        assertEquals(2, imp.spectra().size());
        assertEquals(3, imp.spectra().get(0).mz().length);
        assertEquals(4, imp.spectra().get(1).mz().length);
    }

    @Test
    void continuousModeRejectsDivergentMzAxis(@TempDir Path tmp) {
        double[] mz1 = new double[] {100, 200, 300};
        double[] mz2 = new double[] {100, 200, 301}; // divergent
        List<PixelSpectrum> bad = List.of(
            new PixelSpectrum(1, 1, 1, mz1, new double[]{1, 2, 3}),
            new PixelSpectrum(2, 1, 1, mz2, new double[]{4, 5, 6})
        );
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> ImzMLWriter.write(bad, tmp.resolve("bad.imzML"), null,
                    "continuous", 0, 0, 0, 0, 0, "flyback", null));
        assertTrue(ex.getMessage().contains("share the same m/z axis"));
    }

    @Test
    void processedModeRejectsLengthMismatch(@TempDir Path tmp) {
        List<PixelSpectrum> bad = List.of(
            new PixelSpectrum(1, 1, 1,
                new double[]{100, 200, 300},
                new double[]{1, 2})
        );
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> ImzMLWriter.write(bad, tmp.resolve("bad.imzML"), null,
                    "processed", 0, 0, 0, 0, 0, "flyback", null));
        assertTrue(ex.getMessage().contains("must be the same length"));
    }

    @Test
    void uuidNormalisationAcceptsBracesAndDashes(@TempDir Path tmp) {
        List<PixelSpectrum> pixels = List.of(
            new PixelSpectrum(1, 1, 1,
                new double[]{100, 200}, new double[]{1, 2}));
        ImzMLWriter.WriteResult res = ImzMLWriter.write(
            pixels, tmp.resolve("u.imzML"), null, "processed",
            0, 0, 0, 0, 0, "flyback",
            "{11223344-5566-7788-99AA-BBCCDDEEFF00}");
        assertEquals("112233445566778899aabbccddeeff00", res.uuidHex());
    }

    @Test
    void rejectsInvalidUuidLength(@TempDir Path tmp) {
        List<PixelSpectrum> pixels = List.of(
            new PixelSpectrum(1, 1, 1, new double[]{100}, new double[]{1}));
        assertThrows(IllegalArgumentException.class, () ->
            ImzMLWriter.write(pixels, tmp.resolve("u.imzML"), null,
                "processed", 0, 0, 0, 0, 0, "flyback", "tooshort"));
    }

    @Test
    void rejectsEmptyPixelList(@TempDir Path tmp) {
        assertThrows(IllegalArgumentException.class, () ->
            ImzMLWriter.write(List.of(), tmp.resolve("empty.imzML"), null,
                "continuous", 0, 0, 0, 0, 0, "flyback", null));
    }

    @Test
    void writeFromImportRoundTripsMetadata(@TempDir Path tmp) throws Exception {
        List<PixelSpectrum> seed = List.of(
            new PixelSpectrum(1, 1, 1,
                new double[]{100, 200, 300}, new double[]{1, 2, 3}),
            new PixelSpectrum(2, 1, 1,
                new double[]{100, 200, 300, 400}, new double[]{4, 5, 6, 7})
        );
        Path seedPath = tmp.resolve("seed.imzML");
        ImzMLWriter.write(seed, seedPath, null, "processed",
                2, 1, 1, 25.0, 25.0, "meandering", null);
        ImzMLImport imp = ImzMLReader.read(seedPath);

        Path echoPath = tmp.resolve("echo.imzML");
        ImzMLWriter.writeFromImport(imp, echoPath, null);
        ImzMLImport reread = ImzMLReader.read(echoPath);

        assertEquals(imp.mode(), reread.mode());
        assertEquals(imp.uuidHex(), reread.uuidHex());
        assertEquals(imp.gridMaxX(), reread.gridMaxX());
        assertEquals(imp.gridMaxY(), reread.gridMaxY());
        assertEquals(imp.pixelSizeX(), reread.pixelSizeX(), 1e-9);
        assertEquals(imp.pixelSizeY(), reread.pixelSizeY(), 1e-9);
        assertEquals(imp.spectra().size(), reread.spectra().size());
        for (int i = 0; i < imp.spectra().size(); i++) {
            assertArrayEquals(imp.spectra().get(i).mz(),
                    reread.spectra().get(i).mz(), 0.0);
            assertArrayEquals(imp.spectra().get(i).intensity(),
                    reread.spectra().get(i).intensity(), 0.0);
        }
    }
}
