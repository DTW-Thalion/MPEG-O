/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.SamplingMode;
import global.thalion.ttio.exporters.JcampDxWriter;
import global.thalion.ttio.importers.JcampDxDecode;
import global.thalion.ttio.importers.JcampDxReader;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11.1 (M73.1) acceptance: JCAMP-DX compression + UV-Vis +
 * TwoDimensionalCorrelationSpectrum parity tests.
 */
class Milestone73_1Test {

    @TempDir Path tempDir;

    // ── has_compression detection ───────────────────────────────────

    @Test void hasCompressionDetectsSqz() {
        assertTrue(JcampDxDecode.hasCompression("450.0A3000B250"));
    }

    @Test void hasCompressionDetectsDif() {
        assertTrue(JcampDxDecode.hasCompression("450.0%J3K2"));
    }

    @Test void hasCompressionDetectsDup() {
        assertTrue(JcampDxDecode.hasCompression("450.0@5S"));
    }

    @Test void hasCompressionFalseForAffn() {
        assertFalse(JcampDxDecode.hasCompression("450.0 12.5\n451.0 13.0\n"));
    }

    @Test void hasCompressionFalseForScientific() {
        assertFalse(JcampDxDecode.hasCompression("450.0 1.234e-05\n451.0 9.87E+03\n"));
    }

    // ── SQZ ────────────────────────────────────────────────────────

    @Test void sqzPositiveSingleDigit() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A B C"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{100.0, 101.0, 102.0}, d.xs, 0.0);
        assertArrayEquals(new double[]{1.0, 2.0, 3.0}, d.ys, 0.0);
    }

    @Test void sqzMultiDigit() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A23"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{123.0}, d.ys, 0.0);
    }

    @Test void sqzNegative() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 a b"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{-1.0, -2.0}, d.ys, 0.0);
    }

    @Test void sqzAtZero() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 @"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{0.0}, d.ys, 0.0);
    }

    // ── DIF ────────────────────────────────────────────────────────

    @Test void difCumulative() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A J K"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{1.0, 2.0, 4.0}, d.ys, 0.0);
    }

    @Test void difPercentZeroDelta() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A %"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{1.0, 1.0}, d.ys, 0.0);
    }

    @Test void difNegative() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 C j k"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{3.0, 2.0, 0.0}, d.ys, 0.0);
    }

    // ── DUP ────────────────────────────────────────────────────────

    @Test void dupRepeatsPrior() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A S"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{1.0, 1.0}, d.ys, 0.0);
    }

    @Test void dupLargerCount() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A U"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{1.0, 1.0, 1.0, 1.0}, d.ys, 0.0);
    }

    // ── DIF Y-check ────────────────────────────────────────────────

    @Test void difYCheckDropped() {
        JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
            List.of("100 A J", "102 B"), 100.0, 1.0, 1.0, 1.0);
        assertArrayEquals(new double[]{1.0, 2.0}, d.ys, 0.0);
    }

    // ── Compressed file round-trip via reader ──────────────────────

    @Test void compressedXydataRoundTripViaReader() throws IOException {
        String jdx =
            "##TITLE=compressed\n"
            + "##JCAMP-DX=5.01\n"
            + "##DATA TYPE=INFRARED ABSORBANCE\n"
            + "##XUNITS=1/CM\n"
            + "##YUNITS=ABSORBANCE\n"
            + "##FIRSTX=100\n"
            + "##LASTX=104\n"
            + "##NPOINTS=5\n"
            + "##XFACTOR=1\n"
            + "##YFACTOR=1\n"
            + "##XYDATA=(X++(Y..Y))\n"
            + "100 A J J J J\n"
            + "##END=\n";
        Path p = tempDir.resolve("compressed_ir.jdx");
        Files.writeString(p, jdx);
        Spectrum decoded = JcampDxReader.readSpectrum(p);
        assertInstanceOf(IRSpectrum.class, decoded);
        IRSpectrum ir = (IRSpectrum) decoded;
        assertArrayEquals(new double[]{100.0, 101.0, 102.0, 103.0, 104.0},
                          ir.wavenumberValues(), 1e-12);
        assertArrayEquals(new double[]{1.0, 2.0, 3.0, 4.0, 5.0},
                          ir.intensityValues(), 1e-12);
    }

    @Test void compressedRequiresFirstxLastxNpoints() throws IOException {
        String jdx =
            "##TITLE=no_headers\n"
            + "##JCAMP-DX=5.01\n"
            + "##DATA TYPE=INFRARED ABSORBANCE\n"
            + "##XYDATA=(X++(Y..Y))\n"
            + "100 A J J J J\n"
            + "##END=\n";
        Path p = tempDir.resolve("bad.jdx");
        Files.writeString(p, jdx);
        assertThrows(IllegalArgumentException.class,
            () -> JcampDxReader.readSpectrum(p));
    }

    // ── UV-Vis ─────────────────────────────────────────────────────

    @Test void uvVisSpectrumConstructs() {
        double[] wl = new double[601];
        double[] ab = new double[601];
        for (int i = 0; i < 601; i++) {
            wl[i] = 200.0 + i;
            double z = (wl[i] - 450.0) / 40.0;
            ab[i] = Math.exp(-z * z);
        }
        UVVisSpectrum s = new UVVisSpectrum(wl, ab, 0, 0.0, 1.0, "methanol");
        assertEquals(601, s.wavelengthValues().length);
        assertEquals(1.0, s.pathLengthCm());
        assertEquals("methanol", s.solvent());
    }

    @Test void uvVisJcampRoundTrip() throws IOException {
        double[] wl = new double[601];
        double[] ab = new double[601];
        for (int i = 0; i < 601; i++) {
            wl[i] = 200.0 + i;
            double z = (wl[i] - 450.0) / 40.0;
            ab[i] = Math.exp(-z * z);
        }
        UVVisSpectrum original = new UVVisSpectrum(wl, ab, 0, 0.0, 1.0, "methanol");
        Path p = tempDir.resolve("uvvis.jdx");
        JcampDxWriter.writeUVVisSpectrum(original, p, "test UV-Vis");
        Spectrum decoded = JcampDxReader.readSpectrum(p);
        assertInstanceOf(UVVisSpectrum.class, decoded);
        UVVisSpectrum uv = (UVVisSpectrum) decoded;
        assertEquals(1.0, uv.pathLengthCm(), 1e-9);
        assertEquals("methanol", uv.solvent());
        double[] wlDec = uv.wavelengthValues();
        double[] abDec = uv.absorbanceValues();
        for (int i = 0; i < 601; i++) {
            assertEquals(wl[i], wlDec[i], 1e-9);
            assertEquals(ab[i], abDec[i], Math.abs(ab[i]) * 1e-9 + 1e-12);
        }
    }

    @Test void uvVisAlternateDataTypeSpellings() throws IOException {
        String[] variants = {
            "UV/VIS SPECTRUM", "UV-VIS SPECTRUM", "UV/VISIBLE SPECTRUM"
        };
        for (String v : variants) {
            String jdx =
                "##TITLE=variant\n"
                + "##JCAMP-DX=5.01\n"
                + "##DATA TYPE=" + v + "\n"
                + "##XUNITS=NANOMETERS\n"
                + "##YUNITS=ABSORBANCE\n"
                + "##XYDATA=(X++(Y..Y))\n"
                + "200 0.1\n"
                + "250 0.2\n"
                + "##END=\n";
            Path p = tempDir.resolve("v_" + v.replace('/', '_') + ".jdx");
            Files.writeString(p, jdx);
            Spectrum decoded = JcampDxReader.readSpectrum(p);
            assertInstanceOf(UVVisSpectrum.class, decoded,
                "variant=" + v);
        }
    }

    // ── 2D correlation spectrum ────────────────────────────────────

    @Test void twoDCosConstructs() {
        int n = 16;
        double[] sync = new double[n * n];
        double[] asyn = new double[n * n];
        for (int i = 0; i < n * n; i++) { sync[i] = i * 0.5; asyn[i] = -i * 0.25; }
        TwoDimensionalCorrelationSpectrum s = new TwoDimensionalCorrelationSpectrum(
            sync, asyn, n,
            new AxisDescriptor("wavenumber", "1/cm", null, SamplingMode.NON_UNIFORM),
            "temperature", "K", "ir");
        assertEquals(n, s.matrixSize());
        assertEquals("temperature", s.perturbation());
        assertEquals("K", s.perturbationUnit());
        assertEquals("ir", s.sourceModality());
        assertNotNull(s.variableAxis());
        assertEquals("1/cm", s.variableAxis().unit());
    }

    @Test void twoDCosRejectsSyncLengthMismatch() {
        assertThrows(IllegalArgumentException.class, () ->
            new TwoDimensionalCorrelationSpectrum(
                new double[9],      // 3x3 expected but size=4
                new double[16],     // 4x4 expected
                4, null, "", "", ""));
    }

    @Test void twoDCosRejectsAsyncLengthMismatch() {
        assertThrows(IllegalArgumentException.class, () ->
            new TwoDimensionalCorrelationSpectrum(
                new double[16],
                new double[9],
                4, null, "", "", ""));
    }

    @Test void twoDCosNullMatricesThrow() {
        assertThrows(IllegalArgumentException.class, () ->
            new TwoDimensionalCorrelationSpectrum(
                null, new double[16], 4, null, "", "", ""));
    }
}
