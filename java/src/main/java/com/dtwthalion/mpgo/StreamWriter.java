/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.AcquisitionMode;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

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
 * <p><b>API status:</b> Stable.</p>
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

    /**
     * Rewrite the target file with all buffered spectra so far.
     *
     * <p>Flattens the buffered spectra into concatenated m/z and intensity
     * arrays, builds a {@link SpectrumIndex} and an {@link AcquisitionRun},
     * then delegates to {@link SpectralDataset#create} so the file is a
     * valid {@code .mpgo} after each call.</p>
     */
    public void flush() {
        int n = spectra.size();
        int totalPoints = spectra.stream().mapToInt(s -> s.mzValues().length).sum();

        double[] mzAll = new double[totalPoints];
        double[] intensityAll = new double[totalPoints];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        double[] rts = new double[n];
        int[] msLevels = new int[n];
        int[] polarities = new int[n];
        double[] precursorMzs = new double[n];
        int[] precursorCharges = new int[n];
        double[] basePeakIntensities = new double[n];

        int offset = 0;
        for (int i = 0; i < n; i++) {
            MassSpectrum ms = spectra.get(i);
            double[] mz = ms.mzValues();
            double[] intensity = ms.intensityValues();
            System.arraycopy(mz, 0, mzAll, offset, mz.length);
            System.arraycopy(intensity, 0, intensityAll, offset, intensity.length);
            offsets[i] = offset;
            lengths[i] = mz.length;
            rts[i] = ms.scanTimeSeconds();
            msLevels[i] = ms.msLevel();
            polarities[i] = ms.polarity().intValue();
            precursorMzs[i] = ms.precursorMz();
            precursorCharges[i] = ms.precursorCharge();
            double basePeak = 0.0;
            for (int j = 0; j < intensity.length; j++) {
                if (intensity[j] > basePeak) basePeak = intensity[j];
            }
            basePeakIntensities[i] = basePeak;
            offset += mz.length;
        }

        SpectrumIndex idx = new SpectrumIndex(n,
            offsets, lengths, rts, msLevels, polarities,
            precursorMzs, precursorCharges, basePeakIntensities);

        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mzAll);
        channels.put("intensity", intensityAll);

        AcquisitionRun run = new AcquisitionRun(
            runName,
            acquisitionMode,
            idx,
            instrumentConfig,
            channels,
            List.of(),
            List.of(),
            null,
            0.0
        );

        try (SpectralDataset ds = SpectralDataset.create(
                filePath, "", null,
                List.of(run),
                List.of(), List.of(), List.of())) {
            // file written; ds closed by try-with-resources
        }
    }

    public void flushAndClose() {
        flush();
    }

    @Override
    public void close() {
        spectra.clear();
    }
}
