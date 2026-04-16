/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.Polarity;
import java.util.*;

public class MassSpectrum extends Spectrum {
    private final int msLevel;
    private final Polarity polarity;
    private final double precursorMz;
    private final int precursorCharge;
    private final ValueRange scanWindow; // nullable

    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        int msLevel, Polarity polarity,
                        double precursorMz, int precursorCharge,
                        ValueRange scanWindow) {
        super(Map.of(
            "mz", SignalArray.ofDoubles(mzValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), indexPosition, scanTimeSeconds);
        this.msLevel = msLevel;
        this.polarity = polarity;
        this.precursorMz = precursorMz;
        this.precursorCharge = precursorCharge;
        this.scanWindow = scanWindow;
    }

    public double[] mzValues() { return signalArray("mz").asDoubles(); }
    public double[] intensityValues() { return signalArray("intensity").asDoubles(); }
    public int msLevel() { return msLevel; }
    public Polarity polarity() { return polarity; }
    public double precursorMz() { return precursorMz; }
    public int precursorCharge() { return precursorCharge; }
    public ValueRange scanWindow() { return scanWindow; }
}
