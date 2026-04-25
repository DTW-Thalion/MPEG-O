/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.Map;

/**
 * 1-D NMR spectrum: chemical-shift + intensity arrays plus nucleus
 * type and spectrometer frequency in MHz.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIONMRSpectrum}, Python
 * {@code ttio.nmr_spectrum.NMRSpectrum}.</p>
 *
 * @since 0.6
 */
public class NMRSpectrum extends Spectrum {
    private final String nucleusType;
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

    /** Returns the {@code "chemical_shift"} {@link SignalArray}. */
    public SignalArray chemicalShiftArray() { return signalArray("chemical_shift"); }

    /** Returns the {@code "intensity"} {@link SignalArray}. */
    public SignalArray intensityArray() { return signalArray("intensity"); }

    /** Convenience: chemical-shift values as a primitive array. */
    public double[] chemicalShiftValues() { return chemicalShiftArray().asDoubles(); }

    /** Convenience: intensity values as a primitive array. */
    public double[] intensityValues() { return intensityArray().asDoubles(); }

    /** Nucleus type, e.g. {@code "1H"}, {@code "13C"}, {@code "31P"}. */
    public String nucleusType() { return nucleusType; }

    /** Spectrometer frequency in MHz. */
    public double spectrometerFrequencyMHz() { return spectrometerFrequencyMHz; }
}
