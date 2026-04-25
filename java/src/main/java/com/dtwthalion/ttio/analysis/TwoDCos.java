/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.analysis;

import com.dtwthalion.ttio.AxisDescriptor;
import com.dtwthalion.ttio.TwoDimensionalCorrelationSpectrum;

/**
 * 2D-COS compute primitives — Noda's synchronous / asynchronous
 * decomposition from a perturbation series (Hilbert-transform approach).
 *
 * <p>Given a dynamic-spectra matrix {@code A} of shape {@code (m, n)}
 * (m perturbation points × n spectral variables) and a reference
 * spectrum (default: column-wise mean), the dynamic matrix
 * {@code Ã = A − reference} is decomposed into:</p>
 * <ul>
 *   <li>Synchronous {@code Φ = (1/(m−1)) · Ãᵀ · Ã}, symmetric.</li>
 *   <li>Asynchronous {@code Ψ = (1/(m−1)) · Ãᵀ · N · Ã}, antisymmetric,
 *       where {@code N} is the discrete Hilbert-Noda transform matrix.</li>
 * </ul>
 *
 * <p>All matrices are stored row-major as flat {@code double[]}.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.analysis.two_d_cos}, Objective-C {@code TTIOTwoDCos}.</p>
 *
 * @since 0.12.0
 */
public final class TwoDCos {

    private TwoDCos() { }

    /**
     * Return the discrete Hilbert-Noda transform matrix of size
     * {@code (m, m)}, row-major. Entry {@code (j, k)} is {@code 0} on
     * the diagonal and {@code 1 / (π · (k − j))} off-diagonal.
     *
     * @param m matrix order (must be ≥ 1)
     */
    public static double[] hilbertNodaMatrix(int m) {
        if (m < 1) {
            throw new IllegalArgumentException("m must be >= 1, got " + m);
        }
        double[] n = new double[m * m];
        for (int j = 0; j < m; j++) {
            for (int k = 0; k < m; k++) {
                if (j == k) {
                    n[j * m + k] = 0.0;
                } else {
                    n[j * m + k] = 1.0 / (Math.PI * (double) (k - j));
                }
            }
        }
        return n;
    }

    /**
     * Compute the mean-centered 2D-COS decomposition.
     *
     * @param dynamicSpectra row-major flat {@code double[]} of length {@code m * n}
     * @param m              number of perturbation points (rows)
     * @param n              number of spectral variables (cols)
     */
    public static TwoDimensionalCorrelationSpectrum compute(double[] dynamicSpectra,
                                                            int m,
                                                            int n) {
        return compute(dynamicSpectra, m, n, null, null, "", "", "");
    }

    /**
     * Compute the 2D-COS decomposition with full metadata and optional
     * explicit reference spectrum.
     *
     * @param dynamicSpectra    row-major flat input, length {@code m * n}
     * @param m                 perturbation points
     * @param n                 spectral variables
     * @param reference         length-{@code n} baseline to subtract (null = column mean)
     * @param variableAxis      forwarded to the returned spectrum
     * @param perturbation      forwarded to the returned spectrum
     * @param perturbationUnit  forwarded to the returned spectrum
     * @param sourceModality    forwarded to the returned spectrum
     */
    public static TwoDimensionalCorrelationSpectrum compute(double[] dynamicSpectra,
                                                            int m,
                                                            int n,
                                                            double[] reference,
                                                            AxisDescriptor variableAxis,
                                                            String perturbation,
                                                            String perturbationUnit,
                                                            String sourceModality) {
        if (dynamicSpectra == null) {
            throw new IllegalArgumentException("dynamicSpectra must not be null");
        }
        if (m < 2) {
            throw new IllegalArgumentException(
                "need >= 2 perturbation points for 2D-COS, got m=" + m);
        }
        if (n < 1) {
            throw new IllegalArgumentException("n must be >= 1, got " + n);
        }
        if (dynamicSpectra.length != m * n) {
            throw new IllegalArgumentException(
                "dynamicSpectra length " + dynamicSpectra.length
                + " != m*n=" + (m * n));
        }
        double[] ref;
        if (reference == null) {
            ref = new double[n];
            for (int i = 0; i < m; i++) {
                int row = i * n;
                for (int j = 0; j < n; j++) {
                    ref[j] += dynamicSpectra[row + j];
                }
            }
            double inv = 1.0 / (double) m;
            for (int j = 0; j < n; j++) {
                ref[j] *= inv;
            }
        } else {
            if (reference.length != n) {
                throw new IllegalArgumentException(
                    "reference length " + reference.length + " != n=" + n);
            }
            ref = reference;
        }

        // Build mean-centered dynamic matrix A~ (row-major, m x n).
        double[] dyn = new double[m * n];
        for (int i = 0; i < m; i++) {
            int row = i * n;
            for (int j = 0; j < n; j++) {
                dyn[row + j] = dynamicSpectra[row + j] - ref[j];
            }
        }

        double scale = 1.0 / (double) (m - 1);

        // Synchronous: Phi[a, b] = scale * sum_i dyn[i, a] * dyn[i, b]
        double[] sync = new double[n * n];
        for (int a = 0; a < n; a++) {
            for (int b = 0; b < n; b++) {
                double s = 0.0;
                for (int i = 0; i < m; i++) {
                    s += dyn[i * n + a] * dyn[i * n + b];
                }
                sync[a * n + b] = scale * s;
            }
        }

        // Asynchronous: first form tmp = N @ dyn (m x n).
        // N[j, k] = 0 if j==k else 1 / (pi * (k - j)). Avoid building
        // the full matrix — fold the formula into the multiply.
        double[] tmp = new double[m * n];
        double invPi = 1.0 / Math.PI;
        for (int j = 0; j < m; j++) {
            for (int col = 0; col < n; col++) {
                double s = 0.0;
                for (int k = 0; k < m; k++) {
                    if (k == j) continue;
                    s += (invPi / (double) (k - j)) * dyn[k * n + col];
                }
                tmp[j * n + col] = s;
            }
        }

        // Psi = scale * dyn^T @ tmp
        double[] async = new double[n * n];
        for (int a = 0; a < n; a++) {
            for (int b = 0; b < n; b++) {
                double s = 0.0;
                for (int i = 0; i < m; i++) {
                    s += dyn[i * n + a] * tmp[i * n + b];
                }
                async[a * n + b] = scale * s;
            }
        }

        return new TwoDimensionalCorrelationSpectrum(
            sync, async, n, variableAxis,
            perturbation, perturbationUnit, sourceModality
        );
    }

    /**
     * Return {@code |Φ| / (|Φ| + |Ψ|)} — synchronous dominance in
     * {@code [0, 1]}. Cells where both matrices vanish yield
     * {@code Double.NaN}.
     */
    public static double[] disrelationSpectrum(double[] synchronous,
                                               double[] asynchronous) {
        if (synchronous == null || asynchronous == null) {
            throw new IllegalArgumentException("matrices must not be null");
        }
        if (synchronous.length != asynchronous.length) {
            throw new IllegalArgumentException(
                "shape mismatch: " + synchronous.length
                + " vs " + asynchronous.length);
        }
        double[] out = new double[synchronous.length];
        for (int i = 0; i < out.length; i++) {
            double num = Math.abs(synchronous[i]);
            double denom = num + Math.abs(asynchronous[i]);
            out[i] = denom > 0.0 ? num / denom : Double.NaN;
        }
        return out;
    }
}
