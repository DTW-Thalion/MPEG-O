/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.Map;

/**
 * 1-D Raman spectrum: wavenumber + intensity arrays plus laser
 * excitation / power / integration metadata.
 *
 * <p><b>API status:</b> Stable (v0.11, M73).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIORamanSpectrum}, Python
 * {@code ttio.raman_spectrum.RamanSpectrum}.</p>
 *
 * @since 0.11
 */
public class RamanSpectrum extends Spectrum {
    private final double excitationWavelengthNm;
    private final double laserPowerMw;
    private final double integrationTimeSec;

    public RamanSpectrum(double[] wavenumberValues, double[] intensityValues,
                         int indexPosition, double scanTimeSeconds,
                         double excitationWavelengthNm,
                         double laserPowerMw,
                         double integrationTimeSec) {
        super(Map.of(
            "wavenumber", SignalArray.ofDoubles(wavenumberValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), indexPosition, scanTimeSeconds);
        this.excitationWavelengthNm = excitationWavelengthNm;
        this.laserPowerMw = laserPowerMw;
        this.integrationTimeSec = integrationTimeSec;
    }

    /** Returns the {@code "wavenumber"} {@link SignalArray}. */
    public SignalArray wavenumberArray() { return signalArray("wavenumber"); }

    /** Returns the {@code "intensity"} {@link SignalArray}. */
    public SignalArray intensityArray() { return signalArray("intensity"); }

    /** Convenience: wavenumber values as a primitive array. */
    public double[] wavenumberValues() { return wavenumberArray().asDoubles(); }

    /** Convenience: intensity values as a primitive array. */
    public double[] intensityValues() { return intensityArray().asDoubles(); }

    /** Laser excitation wavelength in nanometres (e.g. 532, 785). */
    public double excitationWavelengthNm() { return excitationWavelengthNm; }

    /** Incident laser power in milliwatts. */
    public double laserPowerMw() { return laserPowerMw; }

    /** Detector integration time in seconds. */
    public double integrationTimeSec() { return integrationTimeSec; }
}
