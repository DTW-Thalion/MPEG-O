/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.Map;

/**
 * 2-D NMR spectrum: row-major {@code double[]} intensity matrix of
 * {@code width × height} points plus F1 and F2 axis descriptors.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIONMR2DSpectrum}, Python
 * {@code ttio.nmr_2d.NMR2DSpectrum}.</p>
 *
 *
 */
public class NMR2DSpectrum extends Spectrum {
    private final double[] intensityMatrix;
    private final int width;
    private final int height;
    private final AxisDescriptor f1Axis;
    private final AxisDescriptor f2Axis;
    private final String nucleusF1;
    private final String nucleusF2;

    /**
     * Construct a 2D NMR spectrum from a row-major intensity matrix.
     *
     * @param intensityMatrix flat row-major matrix of shape
     *                        {@code [height, width]}
     * @param width           matrix width (F2 direct dimension)
     * @param height          matrix height (F1 indirect dimension)
     * @param f1Axis          axis descriptor for the F1 (indirect)
     *                        dimension; may be {@code null}
     * @param f2Axis          axis descriptor for the F2 (direct)
     *                        dimension; may be {@code null}
     * @param nucleusF1       nucleus label for F1 (e.g. {@code "1H"})
     * @param nucleusF2       nucleus label for F2 (e.g. {@code "13C"})
     */
    public NMR2DSpectrum(double[] intensityMatrix, int width, int height,
                         AxisDescriptor f1Axis, AxisDescriptor f2Axis,
                         String nucleusF1, String nucleusF2) {
        super(Map.of(), 0, 0.0);
        this.intensityMatrix = intensityMatrix;
        this.width = width;
        this.height = height;
        this.f1Axis = f1Axis;
        this.f2Axis = f2Axis;
        this.nucleusF1 = nucleusF1;
        this.nucleusF2 = nucleusF2;
    }

    /** @return Row-major intensity matrix of shape {@code [height, width]}. */
    public double[] intensityMatrix() { return intensityMatrix; }

    /** @return Matrix width (F2 direct dimension). */
    public int width() { return width; }

    /** @return Matrix height (F1 indirect dimension). */
    public int height() { return height; }

    /** @return Axis descriptor for the F1 (indirect) dimension, or {@code null}. */
    public AxisDescriptor f1Axis() { return f1Axis; }

    /** @return Axis descriptor for the F2 (direct) dimension, or {@code null}. */
    public AxisDescriptor f2Axis() { return f2Axis; }

    /** @return Nucleus label for the F1 dimension (e.g. {@code "1H"}, {@code "13C"}). */
    public String nucleusF1() { return nucleusF1; }

    /** @return Nucleus label for the F2 dimension. */
    public String nucleusF2() { return nucleusF2; }

    /** @return intensity at (row, col). */
    public double valueAt(int row, int col) {
        return intensityMatrix[row * width + col];
    }
}
