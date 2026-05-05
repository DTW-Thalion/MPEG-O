/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.List;
import java.util.Map;

/**
 * Base class for any spectrum. Holds an ordered map of named
 * {@link SignalArray}s plus the coordinate axes that index them,
 * the spectrum's position in its parent run, scan time, and
 * optional precursor info for tandem MS.
 *
 * <p>Concrete subclasses ({@link MassSpectrum}, {@link NMRSpectrum},
 * {@link NMR2DSpectrum}, {@link Chromatogram}) add their own typed
 * metadata.</p>
 *
 * <p><b>HDF5 representation:</b> each spectrum is an HDF5 group
 * whose immediate children are {@code SignalArray} sub-groups
 * (one per named array) plus scalar attributes for the metadata
 * fields.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOSpectrum}, Python
 * {@code ttio.spectrum.Spectrum}.</p>
 *
 *
 */
public class Spectrum {
    private final Map<String, SignalArray> signalArrays;
    private final List<AxisDescriptor> axes;
    private final int indexPosition;
    private final double scanTimeSeconds;
    private final double precursorMz;
    private final int precursorCharge;

    /**
     * Primary constructor.
     *
     * @param signalArrays  named signal arrays (copied defensively)
     * @param axes          coordinate axes (copied defensively)
     * @param indexPosition position in the parent AcquisitionRun (0-based)
     * @param scanTimeSeconds scan time in seconds from run start
     * @param precursorMz   precursor m/z for tandem MS; 0 if not tandem
     * @param precursorCharge precursor charge state; 0 if unknown
     */
    public Spectrum(Map<String, SignalArray> signalArrays,
                    List<AxisDescriptor> axes,
                    int indexPosition, double scanTimeSeconds,
                    double precursorMz, int precursorCharge) {
        this.signalArrays = signalArrays != null ? Map.copyOf(signalArrays) : Map.of();
        this.axes = axes != null ? List.copyOf(axes) : List.of();
        this.indexPosition = indexPosition;
        this.scanTimeSeconds = scanTimeSeconds;
        this.precursorMz = precursorMz;
        this.precursorCharge = precursorCharge;
    }

    /**
     * Convenience constructor for subclasses with no axes or precursor info.
     * Delegates to the 6-arg primary constructor with empty axes and zero
     * precursor fields.
     *
     * @param signalArrays  named signal arrays
     * @param indexPosition position in the parent AcquisitionRun (0-based)
     * @param scanTimeSeconds scan time in seconds from run start
     */
    public Spectrum(Map<String, SignalArray> signalArrays,
                    int indexPosition, double scanTimeSeconds) {
        this(signalArrays, List.of(), indexPosition, scanTimeSeconds, 0.0, 0);
    }

    public Map<String, SignalArray> signalArrays() { return signalArrays; }
    public SignalArray signalArray(String name) { return signalArrays.get(name); }
    public List<AxisDescriptor> axes() { return axes; }
    public int indexPosition() { return indexPosition; }
    public double scanTimeSeconds() { return scanTimeSeconds; }
    public double precursorMz() { return precursorMz; }
    public int precursorCharge() { return precursorCharge; }
}
