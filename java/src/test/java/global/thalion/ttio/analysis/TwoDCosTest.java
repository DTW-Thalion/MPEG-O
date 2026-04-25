/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.analysis;

import global.thalion.ttio.AxisDescriptor;
import global.thalion.ttio.Enums.SamplingMode;
import global.thalion.ttio.TwoDimensionalCorrelationSpectrum;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M77 unit tests for {@link TwoDCos} — Hilbert-Noda matrix structure,
 * validation rejects, zero-dynamic collapse, and sync-symmetric /
 * async-antisymmetric structural invariants.
 */
class TwoDCosTest {

    @Test void hilbertNodaMatrixShapeAndDiagonal() {
        double[] n = TwoDCos.hilbertNodaMatrix(8);
        assertEquals(64, n.length);
        for (int j = 0; j < 8; j++) {
            assertEquals(0.0, n[j * 8 + j], 0.0);
        }
    }

    @Test void hilbertNodaMatrixIsAntisymmetric() {
        int m = 8;
        double[] n = TwoDCos.hilbertNodaMatrix(m);
        for (int j = 0; j < m; j++) {
            for (int k = 0; k < m; k++) {
                assertEquals(n[j * m + k], -n[k * m + j], 1e-15,
                    "antisymmetry at (" + j + "," + k + ")");
            }
        }
    }

    @Test void hilbertNodaMatrixEntries() {
        double[] n = TwoDCos.hilbertNodaMatrix(4);
        assertEquals(1.0 / Math.PI, n[0 * 4 + 1], 1e-15);
        assertEquals(-1.0 / Math.PI, n[1 * 4 + 0], 1e-15);
        assertEquals(1.0 / (3.0 * Math.PI), n[0 * 4 + 3], 1e-15);
    }

    @Test void hilbertNodaMatrixRejectsMZero() {
        assertThrows(IllegalArgumentException.class,
            () -> TwoDCos.hilbertNodaMatrix(0));
    }

    @Test void computeRejectsSingleRow() {
        assertThrows(IllegalArgumentException.class,
            () -> TwoDCos.compute(new double[5], 1, 5));
    }

    @Test void computeRejectsLengthMismatch() {
        assertThrows(IllegalArgumentException.class,
            () -> TwoDCos.compute(new double[10], 3, 4));
    }

    @Test void computeRejectsBadReferenceLength() {
        assertThrows(IllegalArgumentException.class,
            () -> TwoDCos.compute(new double[20], 4, 5,
                new double[7], null, "", "", ""));
    }

    @Test void computeConstantPerturbationYieldsZeroMatrices() {
        int m = 6, n = 12;
        double[] dyn = new double[m * n];
        for (int i = 0; i < m; i++) {
            for (int j = 0; j < n; j++) {
                dyn[i * n + j] = Math.sin(Math.PI * j / (n - 1));
            }
        }
        TwoDimensionalCorrelationSpectrum spec = TwoDCos.compute(dyn, m, n);
        double[] sync = spec.synchronousMatrix();
        double[] async = spec.asynchronousMatrix();
        for (int i = 0; i < n * n; i++) {
            assertEquals(0.0, sync[i], 1e-12);
            assertEquals(0.0, async[i], 1e-12);
        }
    }

    @Test void computeSyncIsSymmetricAsyncIsAntisymmetric() {
        int m = 10, n = 8;
        double[] dyn = new double[m * n];
        // Deterministic "random-ish" input via a cheap hash — avoids
        // depending on any specific RNG implementation.
        long seed = 0xC0FFEEL;
        for (int i = 0; i < m * n; i++) {
            seed = seed * 6364136223846793005L + 1442695040888963407L;
            dyn[i] = ((int) (seed >>> 33)) * (1.0 / (1L << 31));
        }
        TwoDimensionalCorrelationSpectrum spec = TwoDCos.compute(dyn, m, n);
        for (int a = 0; a < n; a++) {
            for (int b = 0; b < n; b++) {
                assertEquals(spec.syncAt(a, b), spec.syncAt(b, a), 1e-12);
                assertEquals(spec.asyncAt(a, b), -spec.asyncAt(b, a), 1e-12);
            }
        }
    }

    @Test void computeCarriesMetadata() {
        AxisDescriptor axis = new AxisDescriptor(
            "wavenumber", "1/cm", null, SamplingMode.UNIFORM);
        double[] dyn = new double[4 * 3];
        for (int i = 0; i < dyn.length; i++) {
            dyn[i] = i * 0.25;
        }
        TwoDimensionalCorrelationSpectrum spec = TwoDCos.compute(
            dyn, 4, 3, null, axis, "temperature", "K", "ir");
        assertEquals(3, spec.matrixSize());
        assertEquals("temperature", spec.perturbation());
        assertEquals("K", spec.perturbationUnit());
        assertEquals("ir", spec.sourceModality());
        assertNotNull(spec.variableAxis());
        assertEquals("1/cm", spec.variableAxis().unit());
    }

    @Test void computeSinePerturbationTwoVariables() {
        int m = 200, n = 2;
        double[] dyn = new double[m * n];
        for (int i = 0; i < m; i++) {
            double t = 2.0 * Math.PI * i / m;
            dyn[i * n + 0] = Math.cos(t);
            dyn[i * n + 1] = Math.cos(t - Math.PI / 2.0);
        }
        TwoDimensionalCorrelationSpectrum spec = TwoDCos.compute(dyn, m, n);
        assertTrue(spec.syncAt(0, 0) > 0.0);
        assertTrue(spec.syncAt(1, 1) > 0.0);
        assertTrue(Math.abs(spec.syncAt(0, 1)) < 5e-2);
        assertTrue(Math.abs(spec.asyncAt(0, 1)) > 1e-2);
        assertEquals(spec.asyncAt(1, 0), -spec.asyncAt(0, 1), 1e-12);
    }

    @Test void disrelationSpectrumBoundsAndNan() {
        double[] sync = { 1.0, 0.0, 3.0, 0.0 };
        double[] async = { 1.0, 0.0, 1.0, 0.0 };
        double[] d = TwoDCos.disrelationSpectrum(sync, async);
        assertEquals(0.5, d[0], 0.0);
        assertTrue(Double.isNaN(d[1]));
        assertEquals(0.75, d[2], 0.0);
        assertTrue(Double.isNaN(d[3]));
    }

    @Test void disrelationSpectrumShapeMismatch() {
        assertThrows(IllegalArgumentException.class,
            () -> TwoDCos.disrelationSpectrum(new double[4], new double[9]));
    }
}
