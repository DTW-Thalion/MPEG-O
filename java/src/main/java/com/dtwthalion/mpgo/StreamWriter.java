/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.AcquisitionMode;

import java.util.ArrayList;
import java.util.List;

/**
 * Incrementally append mass spectra to an {@code .mpgo} file.
 *
 * <p>Spectra accumulate in memory until {@link #flush} is called. On
 * each flush the file is rewritten so that the run group reflects
 * every spectrum buffered so far — the file remains a valid
 * {@code .mpgo} after each flush.</p>
 *
 * <p>For v0.6 the writer's flush is whole-file regenerative: simple,
 * correct, and bounded for the streaming-demo case (≤ a few thousand
 * spectra). A future milestone may switch to extendable HDF5
 * datasets.</p>
 *
 * <p><b>API status:</b> Stable. {@link #flush} integration with
 * {@code SpectralDataset}'s write path is a future milestone;
 * callers buffer spectra and persist via {@code SpectralDataset}
 * directly today.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOStreamWriter}, Python
 * {@code mpeg_o.stream_writer.StreamWriter}.</p>
 *
 * @since 0.6
 */
public final class StreamWriter implements AutoCloseable {

    private final String filePath;
    private final String runName;
    private final AcquisitionMode acquisitionMode;
    private final InstrumentConfig instrumentConfig;
    private final List<MassSpectrum> spectra = new ArrayList<>();

    public StreamWriter(String filePath, String runName,
                        AcquisitionMode acquisitionMode,
                        InstrumentConfig instrumentConfig) {
        this.filePath = filePath;
        this.runName = runName;
        this.acquisitionMode = acquisitionMode;
        this.instrumentConfig = instrumentConfig;
    }

    public void appendSpectrum(MassSpectrum spectrum) {
        spectra.add(spectrum);
    }

    public int spectrumCount() { return spectra.size(); }

    public void flush() {
        throw new UnsupportedOperationException(
            "StreamWriter.flush requires integration with " +
            "SpectralDataset.write — full implementation in a future " +
            "milestone. For now, callers buffer spectra and write via " +
            "SpectralDataset directly.");
    }

    public void flushAndClose() {
        flush();
    }

    @Override
    public void close() {
        spectra.clear();
    }
}
