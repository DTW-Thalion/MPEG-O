/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * A batch of consecutive spectra as parallel arrays: the per-spectrum
 * index columns plus the concatenated channel values, the unit the
 * streaming importers hand to {@link SpectralStreamWriter}. Offsets are
 * relative to the batch. Python: the {@code WrittenRun} batches of
 * {@code ttio.importers.mzml.iter_batches}.
 *
 * @param activationMethods      optional M74 column ({@code null} = absent)
 * @param isolationTargetMzs     optional M74 column
 * @param isolationLowerOffsets  optional M74 column
 * @param isolationUpperOffsets  optional M74 column
 * @param centroideds            optional column
 * @param channelData            channel name to concatenated values
 */
public record WrittenSpectralBatch(long[] offsets, int[] lengths, double[] retentionTimes,
                                   int[] msLevels, int[] polarities, double[] precursorMzs,
                                   int[] precursorCharges, double[] basePeakIntensities,
                                   int[] activationMethods, double[] isolationTargetMzs,
                                   double[] isolationLowerOffsets, double[] isolationUpperOffsets,
                                   int[] centroideds, Map<String, double[]> channelData) {

    public WrittenSpectralBatch {
        channelData = channelData == null ? Map.of() : Map.copyOf(channelData);
        boolean m74Some = activationMethods != null || isolationTargetMzs != null
            || isolationLowerOffsets != null || isolationUpperOffsets != null;
        boolean m74All = activationMethods != null && isolationTargetMzs != null
            && isolationLowerOffsets != null && isolationUpperOffsets != null;
        if (m74Some && !m74All) {
            throw new IllegalArgumentException("M74 columns must be either all present or all absent");
        }
    }

    /** Spectra in the batch. */
    public int spectrumCount() { return offsets.length; }

    /** {@code true} when the four M74 columns are present. */
    public boolean hasM74() { return activationMethods != null; }

    /** Spectra {@code [from, to)} of {@code run} as one batch. */
    public static WrittenSpectralBatch fromRun(AcquisitionRun run, int from, int to) {
        SpectrumIndex idx = run.spectrumIndex();
        int n = to - from;
        long base = idx.offsetAt(from);
        long end = idx.offsetAt(to - 1) + idx.lengthAt(to - 1);
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = idx.offsetAt(from + i) - base;
            lengths[i] = idx.lengthAt(from + i);
        }
        Map<String, double[]> data = new LinkedHashMap<>();
        for (String c : run.channelNames()) {
            data.put(c, run.channelRange(c, base, (int) (end - base)));
        }
        return new WrittenSpectralBatch(offsets, lengths,
            slice(idx.retentionTimes(), from, to), slice(idx.msLevels(), from, to),
            slice(idx.polarities(), from, to), slice(idx.precursorMzs(), from, to),
            slice(idx.precursorCharges(), from, to), slice(idx.basePeakIntensities(), from, to),
            slice(idx.activationMethods(), from, to), slice(idx.isolationTargetMzs(), from, to),
            slice(idx.isolationLowerOffsets(), from, to), slice(idx.isolationUpperOffsets(), from, to),
            slice(idx.centroideds(), from, to), data);
    }

    private static double[] slice(double[] a, int from, int to) {
        return a == null ? null : java.util.Arrays.copyOfRange(a, from, to);
    }

    private static int[] slice(int[] a, int from, int to) {
        return a == null ? null : java.util.Arrays.copyOfRange(a, from, to);
    }
}
