/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.ChromatogramType;

public class Chromatogram {
    private final double[] timeValues;
    private final double[] intensityValues;
    private final ChromatogramType type;
    private final double targetMz;
    private final double precursorMz;
    private final double productMz;

    public Chromatogram(double[] timeValues, double[] intensityValues,
                        ChromatogramType type,
                        double targetMz, double precursorMz, double productMz) {
        this.timeValues = timeValues;
        this.intensityValues = intensityValues;
        this.type = type;
        this.targetMz = targetMz;
        this.precursorMz = precursorMz;
        this.productMz = productMz;
    }

    public static Chromatogram tic(double[] time, double[] intensity) {
        return new Chromatogram(time, intensity, ChromatogramType.TIC, 0, 0, 0);
    }

    public double[] timeValues() { return timeValues; }
    public double[] intensityValues() { return intensityValues; }
    public ChromatogramType type() { return type; }
    public double targetMz() { return targetMz; }
    public double precursorMz() { return precursorMz; }
    public double productMz() { return productMz; }
    public int length() { return timeValues.length; }
}
