/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.util.*;

public class NMRSpectrum extends Spectrum {
    private final String nucleusType;       // e.g., "1H", "13C"
    private final double spectrometerFrequencyMHz;

    public NMRSpectrum(double[] chemicalShiftValues, double[] intensityValues,
                       int indexPosition, double scanTimeSeconds,
                       String nucleusType, double spectrometerFrequencyMHz) {
        super(Map.of(
            "chemical_shift", SignalArray.ofDoubles(chemicalShiftValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), indexPosition, scanTimeSeconds);
        this.nucleusType = nucleusType;
        this.spectrometerFrequencyMHz = spectrometerFrequencyMHz;
    }

    public double[] chemicalShiftValues() { return signalArray("chemical_shift").asDoubles(); }
    public double[] intensityValues() { return signalArray("intensity").asDoubles(); }
    public String nucleusType() { return nucleusType; }
    public double spectrometerFrequencyMHz() { return spectrometerFrequencyMHz; }
}
