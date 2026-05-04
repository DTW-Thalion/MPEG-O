/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.ActivationMethod;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Polarity;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.genomics.GenomicIndex;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

/**
 * Compressed-domain query index for spectra in an acquisition run.
 *
 * <p>Parallel arrays: offsets, lengths, retention times, MS levels,
 * polarities, precursor m/z, precursor charges, base peak intensities.
 * Kept entirely in memory; signal channels remain lazy on disk.</p>
 *
 * <p>HDF5 layout: {@code <run>/spectrum_index/} group with named datasets.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOSpectrumIndex}, Python
 * {@code ttio.acquisition_run.SpectrumIndex}.</p>
 *
 * @since 0.6
 */
public class SpectrumIndex {

    private final int count;
    private final long[] offsets;
    private final int[] lengths;
    private final double[] retentionTimes;
    private final int[] msLevels;
    private final int[] polarities;
    private final double[] precursorMzs;
    private final int[] precursorCharges;
    private final double[] basePeakIntensities;
    // M74 (v0.11): optional parallel columns. Non-null iff the file was
    // written with the opt_ms2_activation_detail feature flag set.
    // All four are null-or-all-populated (enforced by constructors).
    private final int[] activationMethods;
    private final double[] isolationTargetMzs;
    private final double[] isolationLowerOffsets;
    private final double[] isolationUpperOffsets;

    /** Pre-M74 legacy constructor; defaults the four M74 columns to null. */
    public SpectrumIndex(int count, long[] offsets, int[] lengths,
                         double[] retentionTimes, int[] msLevels, int[] polarities,
                         double[] precursorMzs, int[] precursorCharges,
                         double[] basePeakIntensities) {
        this(count, offsets, lengths, retentionTimes, msLevels, polarities,
             precursorMzs, precursorCharges, basePeakIntensities,
             null, null, null, null);
    }

    /** Full (M74) constructor. The four activation / isolation arrays
     *  must be either all-null (no M74 columns on disk) or all non-null
     *  with length equal to {@code count}. */
    public SpectrumIndex(int count, long[] offsets, int[] lengths,
                         double[] retentionTimes, int[] msLevels, int[] polarities,
                         double[] precursorMzs, int[] precursorCharges,
                         double[] basePeakIntensities,
                         int[] activationMethods,
                         double[] isolationTargetMzs,
                         double[] isolationLowerOffsets,
                         double[] isolationUpperOffsets) {
        boolean anyNull = activationMethods == null
                || isolationTargetMzs == null
                || isolationLowerOffsets == null
                || isolationUpperOffsets == null;
        boolean allNull = activationMethods == null
                && isolationTargetMzs == null
                && isolationLowerOffsets == null
                && isolationUpperOffsets == null;
        if (anyNull && !allNull) {
            throw new IllegalArgumentException(
                "M74 columns must be all-null or all-populated");
        }
        this.count = count;
        this.offsets = offsets;
        this.lengths = lengths;
        this.retentionTimes = retentionTimes;
        this.msLevels = msLevels;
        this.polarities = polarities;
        this.precursorMzs = precursorMzs;
        this.precursorCharges = precursorCharges;
        this.basePeakIntensities = basePeakIntensities;
        this.activationMethods = activationMethods;
        this.isolationTargetMzs = isolationTargetMzs;
        this.isolationLowerOffsets = isolationLowerOffsets;
        this.isolationUpperOffsets = isolationUpperOffsets;
    }

    public int count() { return count; }
    public long[] offsets() { return offsets; }
    public int[] lengths() { return lengths; }
    public double[] retentionTimes() { return retentionTimes; }
    public int[] msLevels() { return msLevels; }
    public int[] polarities() { return polarities; }
    public double[] precursorMzs() { return precursorMzs; }
    public int[] precursorCharges() { return precursorCharges; }
    public double[] basePeakIntensities() { return basePeakIntensities; }

    public long offsetAt(int i) { return offsets[i]; }
    public int lengthAt(int i) { return lengths[i]; }
    public double retentionTimeAt(int i) { return retentionTimes[i]; }
    public int msLevelAt(int i) { return msLevels[i]; }
    public Polarity polarityAt(int i) { return Polarity.fromInt(polarities[i]); }
    public double precursorMzAt(int i) { return precursorMzs[i]; }
    public int precursorChargeAt(int i) { return precursorCharges[i]; }
    public double basePeakIntensityAt(int i) { return basePeakIntensities[i]; }

    /** (M74) Optional parallel columns; {@code null} when the file
     *  was written without {@code opt_ms2_activation_detail}. */
    public int[] activationMethods() { return activationMethods; }
    public double[] isolationTargetMzs() { return isolationTargetMzs; }
    public double[] isolationLowerOffsets() { return isolationLowerOffsets; }
    public double[] isolationUpperOffsets() { return isolationUpperOffsets; }

    /** (M74) Returns the activation method at spectrum {@code i};
     *  {@link ActivationMethod#NONE} when the M74 column is absent or
     *  the stored value is 0. */
    public ActivationMethod activationMethodAt(int i) {
        if (activationMethods == null) return ActivationMethod.NONE;
        return ActivationMethod.fromInt(activationMethods[i]);
    }

    /** (M74) Returns the isolation window at spectrum {@code i}, or
     *  {@code null} when the M74 columns are absent or the stored
     *  target+offsets are all zero (MS1 sentinel). */
    public IsolationWindow isolationWindowAt(int i) {
        if (isolationTargetMzs == null || isolationLowerOffsets == null
                || isolationUpperOffsets == null) return null;
        double t = isolationTargetMzs[i];
        double l = isolationLowerOffsets[i];
        double u = isolationUpperOffsets[i];
        if (t == 0.0 && l == 0.0 && u == 0.0) return null;
        return new IsolationWindow(t, l, u);
    }

    /**
     * @return indices whose retention time lies within
     *         {@code [range.minimum(), range.maximum()]}.
     */
    public java.util.List<Integer> indicesInRetentionTimeRange(ValueRange range) {
        java.util.List<Integer> out = new java.util.ArrayList<>();
        for (int i = 0; i < count; i++) {
            double t = retentionTimes[i];
            if (t >= range.minimum() && t <= range.maximum()) out.add(i);
        }
        return out;
    }

    /** @return indices whose {@code msLevel} equals {@code msLevel}. */
    public java.util.List<Integer> indicesForMsLevel(int msLevel) {
        java.util.List<Integer> out = new java.util.ArrayList<>();
        for (int i = 0; i < count; i++) if (msLevels[i] == msLevel) out.add(i);
        return out;
    }

    /** Write this index to a storage group (creates spectrum_index/ subgroup).
     *
     *  <p>v0.7 M44: parameter type relaxed to {@link StorageGroup} so the
     *  index can be written through any provider (HDF5, SQLite, Memory).</p>
     *
     *  <p>v1.10 #10: equivalent to {@link #writeTo(StorageGroup, boolean)
     *  writeTo(runGroup, false)} — omits the redundant {@code offsets}
     *  column.</p> */
    public void writeTo(StorageGroup runGroup) {
        writeTo(runGroup, false);
    }

    /** v1.10 #10 (offsets-cumsum) overload. When {@code keepOffsetsColumn}
     *  is {@code true}, the (mathematically redundant) {@code offsets}
     *  column is written for byte-equivalent backward compat with
     *  pre-v1.10 readers. Default {@code false} — column omitted on disk
     *  and computed from {@code cumsum(lengths)} on read. */
    public void writeTo(StorageGroup runGroup, boolean keepOffsetsColumn) {
        try (StorageGroup idx = runGroup.createGroup("spectrum_index")) {
            idx.setAttribute("count", (long) count);

            if (keepOffsetsColumn) {
                writeDataset(idx, "offsets", Precision.INT64, offsets);
            }
            writeDataset(idx, "lengths", Precision.UINT32, lengths);
            writeDataset(idx, "retention_times", Precision.FLOAT64, retentionTimes);
            writeDataset(idx, "ms_levels", Precision.INT32, msLevels);
            writeDataset(idx, "polarities", Precision.INT32, polarities);
            writeDataset(idx, "precursor_mzs", Precision.FLOAT64, precursorMzs);
            writeDataset(idx, "precursor_charges", Precision.INT32, precursorCharges);
            writeDataset(idx, "base_peak_intensities", Precision.FLOAT64, basePeakIntensities);
            // M74 schema-gating: emit the four optional columns only
            // when they were supplied. Constructor already enforces
            // all-or-nothing, so checking one covers all four.
            if (activationMethods != null) {
                writeDataset(idx, "activation_methods", Precision.INT32, activationMethods);
                writeDataset(idx, "isolation_target_mzs", Precision.FLOAT64, isolationTargetMzs);
                writeDataset(idx, "isolation_lower_offsets", Precision.FLOAT64, isolationLowerOffsets);
                writeDataset(idx, "isolation_upper_offsets", Precision.FLOAT64, isolationUpperOffsets);
            }
        }
    }

    /** Read spectrum index from an existing run group.
     *
     *  <p>v0.7 M44: parameter type relaxed to {@link StorageGroup}.</p> */
    public static SpectrumIndex readFrom(StorageGroup runGroup) {
        try (StorageGroup idx = runGroup.openGroup("spectrum_index")) {
            int count = ((Number) idx.getAttribute("count")).intValue();

            // v1.10 #10: offsets is omitted from disk by default and
            // computed from cumsum(lengths) at read time. Pre-v1.10
            // files have it on disk (read directly).
            int[] lengths = readInts(idx, "lengths");
            long[] offsets = idx.hasChild("offsets")
                ? readLongs(idx, "offsets")
                : GenomicIndex.offsetsFromLengths(lengths);
            double[] retentionTimes = readDoubles(idx, "retention_times");
            int[] msLevels = readInts(idx, "ms_levels");
            int[] polarities = readInts(idx, "polarities");
            double[] precursorMzs = readDoubles(idx, "precursor_mzs");
            int[] precursorCharges = readInts(idx, "precursor_charges");
            double[] basePeakIntensities = readDoubles(idx, "base_peak_intensities");

            // M74 schema-gating: probe for the four optional columns.
            // Present-all or absent-all is the contract; partial
            // presence indicates a malformed file and is flagged.
            boolean hasAct = idx.hasChild("activation_methods");
            boolean hasTgt = idx.hasChild("isolation_target_mzs");
            boolean hasLo = idx.hasChild("isolation_lower_offsets");
            boolean hasHi = idx.hasChild("isolation_upper_offsets");
            if (hasAct != hasTgt || hasAct != hasLo || hasAct != hasHi) {
                throw new IllegalStateException(
                    "spectrum_index is malformed: partial M74 columns present");
            }
            int[] activationMethods = hasAct ? readInts(idx, "activation_methods") : null;
            double[] isolationTargetMzs = hasAct ? readDoubles(idx, "isolation_target_mzs") : null;
            double[] isolationLowerOffsets = hasAct ? readDoubles(idx, "isolation_lower_offsets") : null;
            double[] isolationUpperOffsets = hasAct ? readDoubles(idx, "isolation_upper_offsets") : null;

            return new SpectrumIndex(count, offsets, lengths, retentionTimes,
                    msLevels, polarities, precursorMzs, precursorCharges,
                    basePeakIntensities,
                    activationMethods, isolationTargetMzs,
                    isolationLowerOffsets, isolationUpperOffsets);
        }
    }

    // Format parity: Python and ObjC chunk + zlib-compress the 8
    // parallel index datasets (offsets, lengths, retention_times,
    // ms_levels, polarities, precursor_mzs, precursor_charges,
    // base_peak_intensities). Previously Java wrote them contiguous +
    // uncompressed (chunkSize=0, Compression.NONE) which saved a
    // zlib pass but inflated files by ~4.8 MB at 100 K spectra and
    // broke bit-level parity with the other two writers.
    private static final int INDEX_CHUNK_SIZE = 4096;

    private static void writeDataset(StorageGroup group, String name,
                                     Precision precision, Object data) {
        int len = java.lang.reflect.Array.getLength(data);
        // ZarrProvider (Java v0.8) throws UnsupportedOperationException
        // on compressed datasets — probe and fall back to contiguous
        // uncompressed for providers that don't implement zlib. HDF5
        // and Memory providers take the compressed path.
        StorageDataset ds;
        try {
            ds = group.createDataset(name, precision, len,
                    INDEX_CHUNK_SIZE, Compression.ZLIB, 6);
        } catch (UnsupportedOperationException e) {
            ds = group.createDataset(name, precision, len,
                    0, Compression.NONE, 0);
        }
        try (StorageDataset closeMe = ds) {
            closeMe.writeAll(data);
        }
    }

    private static double[] readDoubles(StorageGroup group, String name) {
        try (StorageDataset ds = group.openDataset(name)) {
            return (double[]) ds.readAll();
        }
    }

    private static int[] readInts(StorageGroup group, String name) {
        try (StorageDataset ds = group.openDataset(name)) {
            return (int[]) ds.readAll();
        }
    }

    private static long[] readLongs(StorageGroup group, String name) {
        try (StorageDataset ds = group.openDataset(name)) {
            return (long[]) ds.readAll();
        }
    }
}
