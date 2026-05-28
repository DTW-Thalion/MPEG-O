/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

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
 *
 */
public class TwoDimensionalCorrelationSpectrum extends Spectrum {
    private final double[] synchronousMatrix;
    private final double[] asynchronousMatrix;
    private final int size;
    private final AxisDescriptor variableAxis;
    private final String perturbation;
    private final String perturbationUnit;
    private final String sourceModality;

    /**
     * Construct a 2D-COS spectrum from synchronous and asynchronous
     * correlation matrices computed by {@link
     * global.thalion.ttio.analysis.TwoDCos}.
     *
     * @param synchronousMatrix  row-major {@code size × size} matrix
     *                           of synchronous correlations
     * @param asynchronousMatrix row-major {@code size × size} matrix
     *                           of asynchronous correlations
     * @param size               side length of both matrices
     * @param variableAxis       axis descriptor for the shared
     *                           variable dimension
     * @param perturbation       perturbation name (e.g.
     *                           {@code "temperature"}); null becomes
     *                           empty
     * @param perturbationUnit   perturbation unit (e.g. {@code "K"});
     *                           null becomes empty
     * @param sourceModality     source modality label (e.g.
     *                           {@code "IR"}, {@code "Raman"}); null
     *                           becomes empty
     * @throws IllegalArgumentException when either matrix is null or
     *         the matrix lengths don't equal {@code size*size}
     */
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

    /** @return Row-major synchronous correlation matrix. */
    public double[] synchronousMatrix() { return synchronousMatrix; }

    /** @return Row-major asynchronous correlation matrix. */
    public double[] asynchronousMatrix() { return asynchronousMatrix; }

    /** Length of the shared variable axis; both matrices are {@code size × size}. */
    public int matrixSize() { return size; }

    /** @return Axis descriptor for the shared variable dimension. */
    public AxisDescriptor variableAxis() { return variableAxis; }

    /** @return Perturbation label (e.g. {@code "temperature"}); empty when unspecified. */
    public String perturbation() { return perturbation; }

    /** @return Perturbation unit (e.g. {@code "K"}); empty when unspecified. */
    public String perturbationUnit() { return perturbationUnit; }

    /** @return Source modality label (e.g. {@code "IR"}, {@code "Raman"}); empty when unspecified. */
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
