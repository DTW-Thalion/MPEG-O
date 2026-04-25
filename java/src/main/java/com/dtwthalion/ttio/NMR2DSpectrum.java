/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

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
 * @since 0.6
 */
public class NMR2DSpectrum extends Spectrum {
    private final double[] intensityMatrix;
    private final int width;
    private final int height;
    private final AxisDescriptor f1Axis;
    private final AxisDescriptor f2Axis;
    private final String nucleusF1;
    private final String nucleusF2;

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

    public double[] intensityMatrix() { return intensityMatrix; }
    public int width() { return width; }
    public int height() { return height; }
    public AxisDescriptor f1Axis() { return f1Axis; }
    public AxisDescriptor f2Axis() { return f2Axis; }
    public String nucleusF1() { return nucleusF1; }
    public String nucleusF2() { return nucleusF2; }

    /** @return intensity at (row, col). */
    public double valueAt(int row, int col) {
        return intensityMatrix[row * width + col];
    }
}
