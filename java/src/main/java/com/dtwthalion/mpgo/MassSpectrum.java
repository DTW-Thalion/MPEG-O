/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.Polarity;

import java.util.Map;

/**
 * A mass spectrum: m/z + intensity arrays plus MS level, polarity,
 * and an optional scan window.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOMassSpectrum}, Python
 * {@code mpeg_o.mass_spectrum.MassSpectrum}.</p>
 *
 * @since 0.6
 */
public class MassSpectrum extends Spectrum {
    private final int msLevel;
    private final Polarity polarity;
    private final ValueRange scanWindow; // nullable

    /**
     * Primary constructor.
     *
     * @param mzValues          raw m/z values (wrapped into a {@link SignalArray})
     * @param intensityValues   raw intensity values (wrapped into a {@link SignalArray})
     * @param indexPosition     position in the parent AcquisitionRun (0-based)
     * @param scanTimeSeconds   scan time in seconds from run start
     * @param precursorMz       precursor m/z for tandem MS; 0 if not tandem
     * @param precursorCharge   precursor charge state; 0 if unknown
     * @param msLevel           MS level (1, 2, 3, ...)
     * @param polarity          ion polarity
     * @param scanWindow        m/z range covered by the scan; {@code null} if not reported
     */
    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        double precursorMz, int precursorCharge,
                        int msLevel, Polarity polarity,
                        ValueRange scanWindow) {
        super(Map.of(
            "mz", SignalArray.ofDoubles(mzValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), java.util.List.of(), indexPosition, scanTimeSeconds,
           precursorMz, precursorCharge);
        this.msLevel = msLevel;
        this.polarity = polarity;
        this.scanWindow = scanWindow;
    }

    /** Returns the {@code "mz"} {@link SignalArray}. */
    public SignalArray mzArray() { return signalArray("mz"); }

    /** Returns the {@code "intensity"} {@link SignalArray}. */
    public SignalArray intensityArray() { return signalArray("intensity"); }

    /** Convenience accessor: raw m/z values as a {@code double[]}. */
    public double[] mzValues() { return mzArray().asDoubles(); }

    /** Convenience accessor: raw intensity values as a {@code double[]}. */
    public double[] intensityValues() { return intensityArray().asDoubles(); }

    /** MS level (1, 2, 3, ...). */
    public int msLevel() { return msLevel; }

    /** Ion polarity. */
    public Polarity polarity() { return polarity; }

    /**
     * m/z range covered by the scan, or {@code null} if not reported.
     */
    public ValueRange scanWindow() { return scanWindow; }
}
