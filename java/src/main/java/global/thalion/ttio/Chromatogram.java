/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
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
 * @since 0.6
 */
public class Chromatogram extends Spectrum {
    private final ChromatogramType type;
    private final double targetMz;
    private final double productMz;
    // precursorMz lives on the base Spectrum class

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

    public static Chromatogram tic(double[] time, double[] intensity) {
        return new Chromatogram(time, intensity, ChromatogramType.TIC, 0, 0, 0);
    }

    public SignalArray timeArray() { return signalArray("time"); }
    public SignalArray intensityArray() { return signalArray("intensity"); }
    public double[] timeValues() { return timeArray().asDoubles(); }
    public double[] intensityValues() { return intensityArray().asDoubles(); }
    public ChromatogramType type() { return type; }
    public double targetMz() { return targetMz; }
    public double productMz() { return productMz; }
    public int length() { return timeValues().length; }
}
