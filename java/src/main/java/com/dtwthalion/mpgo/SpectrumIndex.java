/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.Polarity;
import com.dtwthalion.mpgo.Enums.Precision;
import com.dtwthalion.mpgo.hdf5.Hdf5Dataset;
import com.dtwthalion.mpgo.hdf5.Hdf5Group;

/**
 * Compressed-domain query index for spectra in an acquisition run.
 * Parallel arrays: offsets, lengths, retention times, MS levels, polarities,
 * precursor m/z, precursor charges, base peak intensities.
 *
 * <p>HDF5 layout: {@code <run>/spectrum_index/} group with named datasets.</p>
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

    public SpectrumIndex(int count, long[] offsets, int[] lengths,
                         double[] retentionTimes, int[] msLevels, int[] polarities,
                         double[] precursorMzs, int[] precursorCharges,
                         double[] basePeakIntensities) {
        this.count = count;
        this.offsets = offsets;
        this.lengths = lengths;
        this.retentionTimes = retentionTimes;
        this.msLevels = msLevels;
        this.polarities = polarities;
        this.precursorMzs = precursorMzs;
        this.precursorCharges = precursorCharges;
        this.basePeakIntensities = basePeakIntensities;
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
    public Polarity polarityAt(int i) { return Polarity.fromInt(polarities[i]); }

    /** Write this index to an HDF5 group (creates spectrum_index/ subgroup). */
    public void writeTo(Hdf5Group runGroup) {
        try (Hdf5Group idx = runGroup.createGroup("spectrum_index")) {
            idx.setIntegerAttribute("count", count);

            writeDataset(idx, "offsets", Precision.INT64, offsets);
            writeDataset(idx, "lengths", Precision.UINT32, lengths);
            writeDataset(idx, "retention_times", Precision.FLOAT64, retentionTimes);
            writeDataset(idx, "ms_levels", Precision.INT32, msLevels);
            writeDataset(idx, "polarities", Precision.INT32, polarities);
            writeDataset(idx, "precursor_mzs", Precision.FLOAT64, precursorMzs);
            writeDataset(idx, "precursor_charges", Precision.INT32, precursorCharges);
            writeDataset(idx, "base_peak_intensities", Precision.FLOAT64, basePeakIntensities);
        }
    }

    /** Read spectrum index from an existing run group. */
    public static SpectrumIndex readFrom(Hdf5Group runGroup) {
        try (Hdf5Group idx = runGroup.openGroup("spectrum_index")) {
            int count = (int) idx.readIntegerAttribute("count", 0);

            long[] offsets = readLongs(idx, "offsets");
            int[] lengths = readInts(idx, "lengths");
            double[] retentionTimes = readDoubles(idx, "retention_times");
            int[] msLevels = readInts(idx, "ms_levels");
            int[] polarities = readInts(idx, "polarities");
            double[] precursorMzs = readDoubles(idx, "precursor_mzs");
            int[] precursorCharges = readInts(idx, "precursor_charges");
            double[] basePeakIntensities = readDoubles(idx, "base_peak_intensities");

            return new SpectrumIndex(count, offsets, lengths, retentionTimes,
                    msLevels, polarities, precursorMzs, precursorCharges,
                    basePeakIntensities);
        }
    }

    private static void writeDataset(Hdf5Group group, String name,
                                     Precision precision, Object data) {
        int len = java.lang.reflect.Array.getLength(data);
        try (Hdf5Dataset ds = group.createDataset(name, precision, len, 0, 0)) {
            ds.writeData(data);
        }
    }

    private static double[] readDoubles(Hdf5Group group, String name) {
        try (Hdf5Dataset ds = group.openDataset(name)) {
            return (double[]) ds.readData();
        }
    }

    private static int[] readInts(Hdf5Group group, String name) {
        try (Hdf5Dataset ds = group.openDataset(name)) {
            return (int[]) ds.readData();
        }
    }

    private static long[] readLongs(Hdf5Group group, String name) {
        try (Hdf5Dataset ds = group.openDataset(name)) {
            return (long[]) ds.readData();
        }
    }
}
