/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import global.thalion.ttio.Enums.Precision;
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
 *
 */
public class Hdf5Dataset implements AutoCloseable {

    private long datasetId;
    private final Precision precision;
    private long length;
    private final Hdf5File file;
    private final boolean extendable;
    private boolean closed;

    Hdf5Dataset(long datasetId, Precision precision, long length, Hdf5File file) {
        this(datasetId, precision, length, file, false);
    }

    Hdf5Dataset(long datasetId, Precision precision, long length, Hdf5File file,
                boolean extendable) {
        this.datasetId = datasetId;
        this.precision = precision;
        this.length = length;
        this.file = file;
        this.extendable = extendable;
        this.closed = false;
    }

    /** @return {@code true} when the dataset was created with an
     *  unlimited first dimension and accepts {@link #append}. */
    public boolean isExtendable() { return extendable; }

    /** Extend the dataset by the elements of {@code data} and write them
     *  after the current end. */
    public void append(Object data) {
        if (!extendable) {
            throw new UnsupportedOperationException("dataset is not extendable");
        }
        long n = elementCount(data);
        if (n == 0) return;
        file.lockForWriting();
        try {
            H5.H5Dset_extent(datasetId, new long[]{ length + n });
            writeRange(length, n, data);
            length += n;
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException("H5Dset_extent failed: " + e.getMessage());
        } finally {
            file.unlockForWriting();
        }
    }

    /** Overwrite {@code data}'s elements in place starting at {@code offset}. */
    public void writeSlice(long offset, Object data) {
        long n = elementCount(data);
        if (n == 0) return;
        if (offset < 0 || offset + n > length) {
            throw new Hdf5Errors.OutOfRangeException(offset, n, length);
        }
        file.lockForWriting();
        try {
            writeRange(offset, n, data);
        } finally {
            file.unlockForWriting();
        }
    }

    private void writeRange(long offset, long n, Object data) {
        long htype = -1, fspace = -1, mspace = -1;
        try {
            fspace = H5.H5Dget_space(datasetId);
            H5.H5Sselect_hyperslab(fspace, HDF5Constants.H5S_SELECT_SET,
                    new long[]{ offset }, null, new long[]{ n }, null);
            mspace = H5.H5Screate_simple(1, new long[]{ n }, null);
            htype = Hdf5Group.hdf5TypeFor(precision);
            Object buf = (precision == Precision.COMPLEX128)
                    ? doublesToCompoundBytes((double[]) data) : data;
            int status = H5.H5Dwrite(datasetId, htype, mspace, fspace,
                    HDF5Constants.H5P_DEFAULT, buf);
            if (status < 0) throw new Hdf5Errors.DatasetWriteException("H5Dwrite (range) failed");
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException("H5Dwrite (range) failed: " + e.getMessage());
        } finally {
            if (mspace >= 0) try { H5.H5Sclose(mspace); } catch (Exception ignored) {}
            if (fspace >= 0) try { H5.H5Sclose(fspace); } catch (Exception ignored) {}
            if (precision == Precision.COMPLEX128 && htype >= 0)
                try { H5.H5Tclose(htype); } catch (Exception ignored) {}
        }
    }

    private long elementCount(Object data) {
        if (data instanceof double[] a) return precision == Precision.COMPLEX128 ? a.length / 2 : a.length;
        if (data instanceof float[] a) return a.length;
        if (data instanceof int[] a) return a.length;
        if (data instanceof long[] a) return a.length;
        if (data instanceof short[] a) return a.length;
        if (data instanceof byte[] a) return a.length;
        throw new IllegalArgumentException("unsupported array type " + data.getClass());
    }

    /** @return the underlying HDF5 dataset id. */
    public long getDatasetId() { return datasetId; }

    /** @return the precision (element type) the dataset was created with. */
    public Precision getPrecision() { return precision; }

    /** @return the total element count along all axes. For a 1-D dataset
     *  this equals the single dimension; for N-D datasets it is the
     *  product of all extent values. */
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

    /** Release the underlying dataset id. Idempotent. */
    @Override
    public void close() {
        if (closed) return;
        try {
            H5.H5Dclose(datasetId);
        } catch (HDF5LibraryException ignored) {}
        closed = true;
    }

    // ── Dataset-level attributes ───────────────────────────────────
    //
    // Codec dispatch on signal_channels datasets needs an
    // @compression attribute living on the dataset itself.

    /** Test whether a named attribute exists on this dataset.
     *
     *  @param name  the attribute name
     *  @return {@code true} when the attribute is present
     */
    public boolean hasAttribute(String name) {
        file.lockForReading();
        try {
            return H5.H5Aexists(datasetId, name);
        } catch (HDF5LibraryException e) {
            return false;
        } finally {
            file.unlockForReading();
        }
    }

    /** Write a UTF-8 string attribute on this dataset.
     *
     *  <p>Emits a VL_STRING with UTF-8 character set so Python and ObjC
     *  readers can consume the attribute byte-equivalently. Mirrors
     *  {@link Hdf5Group#setStringAttribute}.</p>
     *
     *  @param name   the attribute name (replaces any existing entry)
     *  @param value  the UTF-8 string payload
     */
    public void setStringAttribute(String name, String value) {
        file.lockForWriting();
        long htype = -1, space = -1, aid = -1;
        try {
            htype = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(htype, HDF5Constants.H5T_VARIABLE);
            H5.H5Tset_strpad(htype, HDF5Constants.H5T_STR_NULLTERM);
            H5.H5Tset_cset(htype, HDF5Constants.H5T_CSET_UTF8);

            space = H5.H5Screate(HDF5Constants.H5S_SCALAR);

            if (H5.H5Aexists(datasetId, name)) {
                H5.H5Adelete(datasetId, name);
            }

            aid = H5.H5Acreate(datasetId, name, htype, space,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) throw new Hdf5Errors.AttributeException(
                    "H5Acreate2 (string) failed for '" + name + "'");

            String[] data = { value };
            H5.H5Awrite_VLStrings(aid, htype, data);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "setStringAttribute failed for '" + name + "': "
                    + e.getMessage());
        } finally {
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            if (space >= 0) try { H5.H5Sclose(space); } catch (Exception ignored) {}
            if (htype >= 0) try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            file.unlockForWriting();
        }
    }

    /** Read a UTF-8 string attribute from this dataset.
     *
     *  <p>Decodes both VL_STRING and fixed-length string attributes.
     *  Returns {@code null} when the attribute is absent <em>or</em> the
     *  attribute's HDF5 type class is not {@code H5T_STRING}. Callers
     *  are expected to dispatch on the return type — {@code null}
     *  indicates "not a string-typed attribute, try a numeric reader".</p>
     *
     *  @param name  the attribute name
     *  @return the decoded string, or {@code null} when the attribute is
     *          absent or non-string typed
     */
    public String readStringAttribute(String name) {
        file.lockForReading();
        long aid = -1, htype = -1;
        try {
            if (!H5.H5Aexists(datasetId, name)) return null;
            aid = H5.H5Aopen(datasetId, name, HDF5Constants.H5P_DEFAULT);
            htype = H5.H5Aget_type(aid);
            int klass = H5.H5Tget_class(htype);
            if (klass != HDF5Constants.H5T_STRING) {
                // Not a string-typed attribute (e.g. uint8 @compression).
                return null;
            }
            if (H5.H5Tis_variable_str(htype)) {
                String[] buf = new String[1];
                H5.H5Aread_VLStrings(aid, htype, buf);
                return buf[0] == null ? "" : buf[0];
            }
            long size = H5.H5Tget_size(htype);
            if (size <= 0) return "";
            byte[] buf = new byte[(int) size];
            H5.H5Aread(aid, htype, buf);
            // Strip trailing NULs from null-terminated padding.
            int realLen = buf.length;
            while (realLen > 0 && buf[realLen - 1] == 0) realLen--;
            return new String(buf, 0, realLen,
                java.nio.charset.StandardCharsets.UTF_8);
        } catch (HDF5LibraryException e) {
            return null;
        } finally {
            if (htype >= 0) try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            file.unlockForReading();
        }
    }

    /** Write a uint8 (one-byte) integer attribute on this dataset.
     *
     *  <p>The {@code @compression} attribute used for codec dispatch
     *  on signal channels carries this datatype
     *  ({@code H5T_NATIVE_UINT8}).</p>
     *
     *  @param name   the attribute name (replaces any existing entry)
     *  @param value  the unsigned 8-bit integer payload (masked to
     *                {@code 0x00..0xFF})
     */
    public void setUint8Attribute(String name, int value) {
        file.lockForWriting();
        long space = -1, aid = -1;
        try {
            space = H5.H5Screate(HDF5Constants.H5S_SCALAR);
            if (H5.H5Aexists(datasetId, name)) {
                H5.H5Adelete(datasetId, name);
            }
            aid = H5.H5Acreate(datasetId, name, HDF5Constants.H5T_NATIVE_UINT8,
                    space, HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) throw new Hdf5Errors.AttributeException(
                    "H5Acreate2 (uint8) failed for '" + name + "'");
            byte[] data = { (byte) (value & 0xFF) };
            H5.H5Awrite(aid, HDF5Constants.H5T_NATIVE_UINT8, data);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "setUint8Attribute failed for '" + name + "': " + e.getMessage());
        } finally {
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            if (space >= 0) try { H5.H5Sclose(space); } catch (Exception ignored) {}
            file.unlockForWriting();
        }
    }

    /** Remove a named attribute. No-op when the attribute is absent.
     *
     *  @param name  the attribute name
     */
    public void deleteAttribute(String name) {
        file.lockForWriting();
        try {
            if (H5.H5Aexists(datasetId, name)) {
                H5.H5Adelete(datasetId, name);
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "H5Adelete failed for '" + name + "': " + e.getMessage());
        } finally {
            file.unlockForWriting();
        }
    }

    /** @return every attribute name on this dataset in HDF5 storage order. */
    public java.util.List<String> attributeNames() {
        file.lockForReading();
        try {
            int n = (int) H5.H5Oget_info(datasetId).num_attrs;
            java.util.List<String> out = new java.util.ArrayList<>(n);
            for (int i = 0; i < n; i++) {
                long aid = H5.H5Aopen_by_idx(datasetId, ".",
                        HDF5Constants.H5_INDEX_NAME, HDF5Constants.H5_ITER_INC,
                        (long) i, HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT);
                try {
                    String nm = H5.H5Aget_name(aid);
                    if (nm != null) out.add(nm);
                } finally {
                    try { H5.H5Aclose(aid); } catch (Exception ignored) {}
                }
            }
            return out;
        } catch (HDF5LibraryException e) {
            return java.util.List.of();
        } finally {
            file.unlockForReading();
        }
    }

    /** Read an integer attribute of any width (uint8 / int64 / …) and
     *  return its value as a long. Returns {@code defaultValue} when
     *  the attribute is absent.
     *
     *  @param name          the attribute name
     *  @param defaultValue  fallback value when the attribute is missing
     *                       or the read fails
     *  @return the attribute value widened to {@code long}
     */
    public long readIntegerAttribute(String name, long defaultValue) {
        file.lockForReading();
        long aid = -1, htype = -1;
        try {
            if (!H5.H5Aexists(datasetId, name)) return defaultValue;
            aid = H5.H5Aopen(datasetId, name, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) return defaultValue;
            htype = H5.H5Aget_type(aid);
            long size = H5.H5Tget_size(htype);
            if (size == 1) {
                byte[] buf = new byte[1];
                H5.H5Aread(aid, HDF5Constants.H5T_NATIVE_UINT8, buf);
                return buf[0] & 0xFFL;
            }
            // Fall through: treat as int64 (covers the legacy integer
            // attributes other modules write via H5T_NATIVE_INT64).
            long[] data = new long[1];
            H5.H5Aread(aid, HDF5Constants.H5T_NATIVE_INT64, data);
            return data[0];
        } catch (HDF5LibraryException e) {
            return defaultValue;
        } finally {
            if (htype >= 0) try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            file.unlockForReading();
        }
    }

    // ── Internal helpers ────────────────────────────────────────────

    private Object allocateBuffer(long count) {
        int n = (int) count;
        return switch (precision) {
            case FLOAT32 -> new float[n];
            case FLOAT64 -> new double[n];
            case INT32, UINT32 -> new int[n];
            case INT64, UINT64 -> new long[n];  // UINT64 packs as long[]
            case COMPLEX128 -> new byte[n * 16];
            case UINT16 -> new short[n];  // chromosome_ids
            case UINT8 -> new byte[n];
            case _RESERVED_INT8 ->
                throw new UnsupportedOperationException(
                    "Precision " + precision + " is reserved (cross-lang parity)");
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
