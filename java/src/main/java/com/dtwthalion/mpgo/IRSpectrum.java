/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.IRMode;

import java.util.Map;

/**
 * 1-D infrared spectrum: wavenumber + intensity arrays plus mode
 * (absorbance vs. transmittance), resolution and co-added scan count.
 *
 * <p><b>API status:</b> Stable (v0.11, M73).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOIRSpectrum}, Python
 * {@code mpeg_o.ir_spectrum.IRSpectrum}.</p>
 *
 * @since 0.11
 */
public class IRSpectrum extends Spectrum {
    private final IRMode mode;
    private final double resolutionCmInv;
    private final long numberOfScans;

    public IRSpectrum(double[] wavenumberValues, double[] intensityValues,
                      int indexPosition, double scanTimeSeconds,
                      IRMode mode,
                      double resolutionCmInv,
                      long numberOfScans) {
        super(Map.of(
            "wavenumber", SignalArray.ofDoubles(wavenumberValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), indexPosition, scanTimeSeconds);
        this.mode = mode != null ? mode : IRMode.TRANSMITTANCE;
        this.resolutionCmInv = resolutionCmInv;
        this.numberOfScans = numberOfScans;
    }

    /** Returns the {@code "wavenumber"} {@link SignalArray}. */
    public SignalArray wavenumberArray() { return signalArray("wavenumber"); }

    /** Returns the {@code "intensity"} {@link SignalArray}. */
    public SignalArray intensityArray() { return signalArray("intensity"); }

    /** Convenience: wavenumber values as a primitive array. */
    public double[] wavenumberValues() { return wavenumberArray().asDoubles(); }

    /** Convenience: intensity values as a primitive array. */
    public double[] intensityValues() { return intensityArray().asDoubles(); }

    /** y-axis interpretation (absorbance vs transmittance). */
    public IRMode mode() { return mode; }

    /** Spectral resolution in reciprocal centimetres. */
    public double resolutionCmInv() { return resolutionCmInv; }

    /** Number of co-added scans producing this spectrum. */
    public long numberOfScans() { return numberOfScans; }
}
