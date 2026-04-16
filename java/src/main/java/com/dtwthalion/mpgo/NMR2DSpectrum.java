/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

public class NMR2DSpectrum {
    private final double[] intensityMatrix; // flattened row-major [height * width]
    private final int width;
    private final int height;
    private final AxisDescriptor f1Axis;
    private final AxisDescriptor f2Axis;
    private final String nucleusF1;
    private final String nucleusF2;
    private final double spectrometerFrequencyMHz;

    public NMR2DSpectrum(double[] intensityMatrix, int width, int height,
                         AxisDescriptor f1Axis, AxisDescriptor f2Axis,
                         String nucleusF1, String nucleusF2,
                         double spectrometerFrequencyMHz) {
        this.intensityMatrix = intensityMatrix;
        this.width = width;
        this.height = height;
        this.f1Axis = f1Axis;
        this.f2Axis = f2Axis;
        this.nucleusF1 = nucleusF1;
        this.nucleusF2 = nucleusF2;
        this.spectrometerFrequencyMHz = spectrometerFrequencyMHz;
    }

    public double[] intensityMatrix() { return intensityMatrix; }
    public int width() { return width; }
    public int height() { return height; }
    public AxisDescriptor f1Axis() { return f1Axis; }
    public AxisDescriptor f2Axis() { return f2Axis; }
    public String nucleusF1() { return nucleusF1; }
    public String nucleusF2() { return nucleusF2; }
    public double spectrometerFrequencyMHz() { return spectrometerFrequencyMHz; }

    /** Get intensity at (row, col). */
    public double valueAt(int row, int col) {
        return intensityMatrix[row * width + col];
    }
}
