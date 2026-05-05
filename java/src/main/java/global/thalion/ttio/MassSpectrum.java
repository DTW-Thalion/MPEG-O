/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.ActivationMethod;
import global.thalion.ttio.Enums.Polarity;

import java.util.Map;

/**
 * A mass spectrum: m/z + intensity arrays plus MS level, polarity,
 * scan window, and optional precursor activation / isolation metadata.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOMassSpectrum}, Python
 * {@code ttio.mass_spectrum.MassSpectrum}.</p>
 *
 *
 */
public class MassSpectrum extends Spectrum {
    private final int msLevel;
    private final Polarity polarity;
    private final ValueRange scanWindow; // nullable
    private final ActivationMethod activationMethod;
    private final IsolationWindow isolationWindow; // nullable

    /**
     * Full constructor including M74 activation and isolation fields.
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
     * @param activationMethod  MS2+ activation method; {@link ActivationMethod#NONE} for MS1
     * @param isolationWindow   MS2+ isolation window; {@code null} for MS1 or when not reported
     */
    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        double precursorMz, int precursorCharge,
                        int msLevel, Polarity polarity,
                        ValueRange scanWindow,
                        ActivationMethod activationMethod,
                        IsolationWindow isolationWindow) {
        super(Map.of(
            "mz", SignalArray.ofDoubles(mzValues),
            "intensity", SignalArray.ofDoubles(intensityValues)
        ), java.util.List.of(), indexPosition, scanTimeSeconds,
           precursorMz, precursorCharge);
        this.msLevel = msLevel;
        this.polarity = polarity;
        this.scanWindow = scanWindow;
        this.activationMethod = activationMethod == null
            ? ActivationMethod.NONE : activationMethod;
        this.isolationWindow = isolationWindow;
    }

    /**
     * Backward-compatible constructor (pre-M74): defaults
     * {@code activationMethod} to {@link ActivationMethod#NONE} and
     * {@code isolationWindow} to {@code null}.
     */
    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        double precursorMz, int precursorCharge,
                        int msLevel, Polarity polarity,
                        ValueRange scanWindow) {
        this(mzValues, intensityValues, indexPosition, scanTimeSeconds,
             precursorMz, precursorCharge, msLevel, polarity, scanWindow,
             ActivationMethod.NONE, null);
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

    /**
     * MS2+ activation method; {@link ActivationMethod#NONE} for MS1 or
     * when the activation method was not reported by the source.
     */
    public ActivationMethod activationMethod() { return activationMethod; }

    /**
     * MS2+ precursor isolation window, or {@code null} for MS1 or when
     * no isolation window was reported.
     */
    public IsolationWindow isolationWindow() { return isolationWindow; }
}
