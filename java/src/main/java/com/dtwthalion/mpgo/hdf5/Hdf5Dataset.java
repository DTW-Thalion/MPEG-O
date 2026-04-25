/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.hdf5;

import com.dtwthalion.mpgo.Enums.Precision;
import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Thin wrapper around a 1-D HDF5 dataset. Owns its dataset id;
 * released in {@link #close()}.
 *
 * <p>Datasets are created with a definite element count and precision;
 * the shape cannot be resized after creation.</p>
 *
 * @since 0.5
 */
public class Hdf5Dataset implements AutoCloseable {

    private long datasetId;
    private final Precision precision;
    private final long length;
    private final Hdf5File file;
    private boolean closed;

    Hdf5Dataset(long datasetId, Precision precision, long length, Hdf5File file) {
        this.datasetId = datasetId;
        this.precision = precision;
        this.length = length;
        this.file = file;
        this.closed = false;
    }

    public long getDatasetId() { return datasetId; }
    public Precision getPrecision() { return precision; }
    public long getLength() { return length; }

    /**
     * Write all elements.
     *
     * <p>The data parameter type depends on the precision:</p>
     * <ul>
     *   <li>FLOAT32: {@code float[]}</li>
     *   <li>FLOAT64: {@code double[]}</li>
     *   <li>INT32: {@code int[]}</li>
     *   <li>INT64: {@code long[]}</li>
     *   <li>UINT32: {@code int[]} (interpreted as unsigned)</li>
     *   <li>COMPLEX128: {@code double[]} with length 2*N (re,im pairs)</li>
     * </ul>
     *
     * @param data array of the appropriate primitive type for this dataset's precision
     */
    public void writeData(Object data) {
        file.lockForWriting();
        long htype = -1;
        try {
            htype = Hdf5Group.hdf5TypeFor(precision);
            Object writeBuffer = (precision == Precision.COMPLEX128)
                    ? doublesToCompoundBytes((double[]) data)
                    : data;
            int status = H5.H5Dwrite(datasetId, htype,
                    HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                    HDF5Constants.H5P_DEFAULT, writeBuffer);
            if (status < 0) throw new Hdf5Errors.DatasetWriteException("H5Dwrite failed");
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException("H5Dwrite failed: " + e.getMessage());
        } finally {
            if (precision == Precision.COMPLEX128 && htype >= 0)
                try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            file.unlockForWriting();
        }
    }

    /**
     * Read all elements. Return type matches the precision (see {@link #writeData}).
     */
    public Object readData() {
        file.lockForReading();
        long htype = -1;
        try {
            htype = Hdf5Group.hdf5TypeFor(precision);
            if (precision == Precision.COMPLEX128) {
                byte[] buf = new byte[(int) (length * 16)];
                int status = H5.H5Dread(datasetId, htype,
                        HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                        HDF5Constants.H5P_DEFAULT, buf);
                if (status < 0) throw new Hdf5Errors.DatasetReadException("H5Dread failed");
                return compoundBytesToDoubles(buf);
            } else {
                Object buf = allocateBuffer(length);
                int status = H5.H5Dread(datasetId, htype,
                        HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                        HDF5Constants.H5P_DEFAULT, buf);
                if (status < 0) throw new Hdf5Errors.DatasetReadException("H5Dread failed");
                return buf;
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetReadException("H5Dread failed: " + e.getMessage());
        } finally {
            if (precision == Precision.COMPLEX128 && htype >= 0)
                try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            file.unlockForReading();
        }
    }

    /**
     * Read a hyperslab: {@code count} elements starting at {@code offset}.
     */
    public Object readData(long offset, long count) {
        if (offset + count > length) {
            throw new Hdf5Errors.OutOfRangeException(offset, count, length);
        }

        file.lockForReading();
        long htype = -1, fspace = -1, mspace = -1;
        try {
            fspace = H5.H5Dget_space(datasetId);
            long[] off = { offset };
            long[] cnt = { count };
            H5.H5Sselect_hyperslab(fspace, HDF5Constants.H5S_SELECT_SET,
                    off, null, cnt, null);

            mspace = H5.H5Screate_simple(1, cnt, null);

            htype = Hdf5Group.hdf5TypeFor(precision);
            if (precision == Precision.COMPLEX128) {
                byte[] buf = new byte[(int) (count * 16)];
                int status = H5.H5Dread(datasetId, htype, mspace, fspace,
                        HDF5Constants.H5P_DEFAULT, buf);
                if (status < 0) throw new Hdf5Errors.DatasetReadException(
                        "H5Dread (hyperslab) failed");
                return compoundBytesToDoubles(buf);
            } else {
                Object buf = allocateBuffer(count);
                int status = H5.H5Dread(datasetId, htype, mspace, fspace,
                        HDF5Constants.H5P_DEFAULT, buf);
                if (status < 0) throw new Hdf5Errors.DatasetReadException(
                        "H5Dread (hyperslab) failed");
                return buf;
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetReadException(
                    "H5Dread (hyperslab) failed: " + e.getMessage());
        } finally {
            if (mspace >= 0) try { H5.H5Sclose(mspace); } catch (Exception ignored) {}
            if (fspace >= 0) try { H5.H5Sclose(fspace); } catch (Exception ignored) {}
            if (precision == Precision.COMPLEX128 && htype >= 0)
                try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            file.unlockForReading();
        }
    }

    @Override
    public void close() {
        if (closed) return;
        try {
            H5.H5Dclose(datasetId);
        } catch (HDF5LibraryException ignored) {}
        closed = true;
    }

    // ── Internal helpers ────────────────────────────────────────────

    private Object allocateBuffer(long count) {
        int n = (int) count;
        return switch (precision) {
            case FLOAT32 -> new float[n];
            case FLOAT64 -> new double[n];
            case INT32, UINT32 -> new int[n];
            case INT64 -> new long[n];
            case COMPLEX128 -> new byte[n * 16];
            case UINT8 -> new byte[n];
        };
    }

    /**
     * Convert interleaved double[] (re,im pairs) to byte[] matching
     * the HDF5 compound layout {double re; double im;}.
     */
    static byte[] doublesToCompoundBytes(double[] data) {
        ByteBuffer bb = ByteBuffer.allocate(data.length * 8);
        bb.order(ByteOrder.nativeOrder());
        for (double v : data) bb.putDouble(v);
        return bb.array();
    }

    /**
     * Convert byte[] from HDF5 compound {double re; double im;}
     * back to interleaved double[].
     */
    static double[] compoundBytesToDoubles(byte[] bytes) {
        ByteBuffer bb = ByteBuffer.wrap(bytes);
        bb.order(ByteOrder.nativeOrder());
        double[] result = new double[bytes.length / 8];
        for (int i = 0; i < result.length; i++) {
            result[i] = bb.getDouble();
        }
        return result;
    }
}
