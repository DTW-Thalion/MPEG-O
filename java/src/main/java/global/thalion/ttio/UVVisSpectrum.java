/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.Map;

/**
 * 1-D UV-visible absorption spectrum: wavelength (nm) and absorbance
 * channels plus path-length and solvent metadata.
 *
 * <p><b>API status:</b> Stable (v0.11.1).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOUVVisSpectrum}, Python
 * {@code ttio.uv_vis_spectrum.UVVisSpectrum}.</p>
 *
 *
 */
public class UVVisSpectrum extends Spectrum {
    private final double pathLengthCm;
    private final String solvent;

    public UVVisSpectrum(double[] wavelengthValues, double[] absorbanceValues,
                         int indexPosition, double scanTimeSeconds,
                         double pathLengthCm, String solvent) {
        super(Map.of(
            "wavelength", SignalArray.ofDoubles(wavelengthValues),
            "absorbance", SignalArray.ofDoubles(absorbanceValues)
        ), indexPosition, scanTimeSeconds);
        this.pathLengthCm = pathLengthCm;
        this.solvent = solvent == null ? "" : solvent;
    }

    /** Returns the {@code "wavelength"} {@link SignalArray}. */
    public SignalArray wavelengthArray() { return signalArray("wavelength"); }

    /** Returns the {@code "absorbance"} {@link SignalArray}. */
    public SignalArray absorbanceArray() { return signalArray("absorbance"); }

    /** Convenience: wavelength values as a primitive array. */
    public double[] wavelengthValues() { return wavelengthArray().asDoubles(); }

    /** Convenience: absorbance values as a primitive array. */
    public double[] absorbanceValues() { return absorbanceArray().asDoubles(); }

    /** Cuvette path length in centimetres. */
    public double pathLengthCm() { return pathLengthCm; }

    /** Solvent description (free-form). */
    public String solvent() { return solvent; }
}
