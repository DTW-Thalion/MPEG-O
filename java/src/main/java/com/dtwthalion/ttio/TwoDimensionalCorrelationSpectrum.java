/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import java.util.Map;

/**
 * 2D correlation spectrum (Noda 2D-COS): synchronous + asynchronous
 * rank-2 correlation matrices sharing a single spectral-variable axis
 * (ν<sub>1</sub> = ν<sub>2</sub>). Both matrices are stored row-major
 * as flat {@code double[]} of length {@code size × size}.
 *
 * <p><b>API status:</b> Stable (v0.11.1).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOTwoDimensionalCorrelationSpectrum}, Python
 * {@code ttio.two_dimensional_correlation_spectrum.TwoDimensionalCorrelationSpectrum}.</p>
 *
 * @since 0.11.1
 */
public class TwoDimensionalCorrelationSpectrum extends Spectrum {
    private final double[] synchronousMatrix;
    private final double[] asynchronousMatrix;
    private final int size;
    private final AxisDescriptor variableAxis;
    private final String perturbation;
    private final String perturbationUnit;
    private final String sourceModality;

    public TwoDimensionalCorrelationSpectrum(double[] synchronousMatrix,
                                             double[] asynchronousMatrix,
                                             int size,
                                             AxisDescriptor variableAxis,
                                             String perturbation,
                                             String perturbationUnit,
                                             String sourceModality) {
        super(Map.of(), 0, 0.0);
        if (synchronousMatrix == null || asynchronousMatrix == null) {
            throw new IllegalArgumentException("matrices must not be null");
        }
        int expected = size * size;
        if (synchronousMatrix.length != expected) {
            throw new IllegalArgumentException(
                "synchronousMatrix length " + synchronousMatrix.length
                + " != size*size=" + expected);
        }
        if (asynchronousMatrix.length != expected) {
            throw new IllegalArgumentException(
                "asynchronousMatrix length " + asynchronousMatrix.length
                + " != size*size=" + expected);
        }
        this.synchronousMatrix = synchronousMatrix;
        this.asynchronousMatrix = asynchronousMatrix;
        this.size = size;
        this.variableAxis = variableAxis;
        this.perturbation = perturbation == null ? "" : perturbation;
        this.perturbationUnit = perturbationUnit == null ? "" : perturbationUnit;
        this.sourceModality = sourceModality == null ? "" : sourceModality;
    }

    public double[] synchronousMatrix() { return synchronousMatrix; }
    public double[] asynchronousMatrix() { return asynchronousMatrix; }

    /** Length of the shared variable axis; both matrices are {@code size × size}. */
    public int matrixSize() { return size; }

    public AxisDescriptor variableAxis() { return variableAxis; }
    public String perturbation() { return perturbation; }
    public String perturbationUnit() { return perturbationUnit; }
    public String sourceModality() { return sourceModality; }

    /** Synchronous-matrix value at {@code (row, col)}. */
    public double syncAt(int row, int col) {
        return synchronousMatrix[row * size + col];
    }

    /** Asynchronous-matrix value at {@code (row, col)}. */
    public double asyncAt(int row, int col) {
        return asynchronousMatrix[row * size + col];
    }
}
