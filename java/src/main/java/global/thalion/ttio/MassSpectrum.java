/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
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
    private final boolean centroided;

    /**
     * Full constructor including M74 activation and isolation fields and
     * the centroided flag.
     */
    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        double precursorMz, int precursorCharge,
                        int msLevel, Polarity polarity,
                        ValueRange scanWindow,
                        ActivationMethod activationMethod,
                        IsolationWindow isolationWindow,
                        boolean centroided) {
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
        this.centroided = centroided;
    }

    /** Pre-centroided constructor; defaults {@code centroided} to {@code false}. */
    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        double precursorMz, int precursorCharge,
                        int msLevel, Polarity polarity,
                        ValueRange scanWindow,
                        ActivationMethod activationMethod,
                        IsolationWindow isolationWindow) {
        this(mzValues, intensityValues, indexPosition, scanTimeSeconds,
             precursorMz, precursorCharge, msLevel, polarity, scanWindow,
             activationMethod, isolationWindow, false);
    }

    /**
     * Backward-compatible constructor (pre-M74): defaults
     * {@code activationMethod} to {@link ActivationMethod#NONE},
     * {@code isolationWindow} to {@code null}, and {@code centroided}
     * to {@code false}.
     */
    public MassSpectrum(double[] mzValues, double[] intensityValues,
                        int indexPosition, double scanTimeSeconds,
                        double precursorMz, int precursorCharge,
                        int msLevel, Polarity polarity,
                        ValueRange scanWindow) {
        this(mzValues, intensityValues, indexPosition, scanTimeSeconds,
             precursorMz, precursorCharge, msLevel, polarity, scanWindow,
             ActivationMethod.NONE, null, false);
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

    /**
     * Returns {@code true} if this spectrum is centroided (mzML
     * MS:1000127), {@code false} for profile mode (MS:1000128) or when
     * the centroided column is absent in the source file.
     *
     * <p><b>Cross-language equivalents:</b> Python
     * {@code MassSpectrum.is_centroided}, Objective-C
     * {@code -[TTIOMassSpectrum isCentroided]}.</p>
     */
    public boolean isCentroided() { return centroided; }
}
