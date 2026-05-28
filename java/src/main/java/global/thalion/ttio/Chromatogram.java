/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.ChromatogramType;

import java.util.List;
import java.util.Map;

/**
 * Chromatogram: time-vs-intensity trace. TIC, XIC, or SRM. Subclass
 * of {@link Spectrum}.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOChromatogram}, Python
 * {@code ttio.chromatogram.Chromatogram}.</p>
 *
 *
 */
public class Chromatogram extends Spectrum {
    private final ChromatogramType type;
    private final double targetMz;
    private final double productMz;
    // precursorMz lives on the base Spectrum class

    /**
     * Construct a chromatogram from parallel time and intensity arrays.
     *
     * @param timeValues       per-point retention times in seconds
     * @param intensityValues  per-point intensities, parallel to {@code timeValues}
     * @param type             TIC, XIC, or SRM
     * @param targetMz         target m/z for XIC; 0 for TIC
     * @param precursorMz      precursor m/z for SRM transitions; 0 otherwise
     * @param productMz        product m/z for SRM transitions; 0 otherwise
     */
    public Chromatogram(double[] timeValues, double[] intensityValues,
                        ChromatogramType type,
                        double targetMz, double precursorMz, double productMz) {
        super(Map.of(
            "time", SignalArray.ofDoubles(timeValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), List.of(), 0, 0.0, precursorMz, 0);
        this.type = type;
        this.targetMz = targetMz;
        this.productMz = productMz;
    }

    /**
     * Convenience factory for a total ion current trace.
     *
     * @param time      retention times in seconds
     * @param intensity TIC intensities parallel to {@code time}
     * @return          chromatogram with {@link ChromatogramType#TIC}
     */
    public static Chromatogram tic(double[] time, double[] intensity) {
        return new Chromatogram(time, intensity, ChromatogramType.TIC, 0, 0, 0);
    }

    /** @return The signal array carrying retention-time values. */
    public SignalArray timeArray() { return signalArray("time"); }

    /** @return The signal array carrying intensity values. */
    public SignalArray intensityArray() { return signalArray("intensity"); }

    /** @return Retention-time values as a {@code double[]}. */
    public double[] timeValues() { return timeArray().asDoubles(); }

    /** @return Intensity values as a {@code double[]} parallel to {@link #timeValues()}. */
    public double[] intensityValues() { return intensityArray().asDoubles(); }

    /** @return The chromatogram kind (TIC, XIC, or SRM). */
    public ChromatogramType type() { return type; }

    /** @return Target m/z for XIC traces; 0 for non-XIC chromatograms. */
    public double targetMz() { return targetMz; }

    /** @return Product m/z for SRM transitions; 0 for non-SRM chromatograms. */
    public double productMz() { return productMz; }

    /** @return Number of points in the chromatogram. */
    public int length() { return timeValues().length; }
}
