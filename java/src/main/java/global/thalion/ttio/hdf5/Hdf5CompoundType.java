/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

import java.util.ArrayList;
import java.util.List;

/**
 * Thin wrapper around an HDF5 compound datatype (H5T_COMPOUND).
 * Supports native numeric fields plus variable-length string fields.
 * Owns the compound type id and every auxiliary VL string type id;
 * all are released in {@link #close()}.
 *
 *
 */
public class Hdf5CompoundType implements AutoCloseable {

    private long typeId;
    private final long totalSize;
    private final List<Long> auxTypeIds = new ArrayList<>();
    private boolean closed;

    /**
     * Create an empty compound type sized to hold {@code totalSize} bytes
     * per record. Fields are added via {@link #addField} or
     * {@link #addVariableLengthStringField} before the type is used.
     *
     * @param totalSize  the byte size of one record (sum of all field
     *                   byte widths)
     * @throws Hdf5Errors.Hdf5Exception  if {@code H5Tcreate} fails
     */
    public Hdf5CompoundType(long totalSize) {
        this.totalSize = totalSize;
        try {
            this.typeId = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, totalSize);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.Hdf5Exception("H5Tcreate(COMPOUND) failed", e);
        }
        this.closed = false;
    }

    /** Insert a native (non-VL) field at the given byte offset.
     *
     *  @param name    the field name as stored in HDF5
     *  @param type    one of the {@code HDF5Constants.H5T_NATIVE_*} ids
     *  @param offset  byte offset of the field within the record
     */
    public void addField(String name, long type, long offset) {
        if (closed || typeId < 0) return;
        try {
            H5.H5Tinsert(typeId, name, offset, type);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.Hdf5Exception(
                    "H5Tinsert failed for field '" + name + "'", e);
        }
    }

    /**
     * Insert a variable-length C string field. Internally copies H5T_C_S1,
     * sets size to H5T_VARIABLE, and retains the aux type id for cleanup.
     *
     * @param name    the field name as stored in HDF5
     * @param offset  byte offset of the field within the record
     */
    public void addVariableLengthStringField(String name, long offset) {
        if (closed || typeId < 0) return;
        try {
            long strType = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(strType, HDF5Constants.H5T_VARIABLE);
            H5.H5Tinsert(typeId, name, offset, strType);
            auxTypeIds.add(strType);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.Hdf5Exception(
                    "addVariableLengthStringField failed for '" + name + "'", e);
        }
    }

    /** @return the underlying HDF5 type id, or {@code -1} after close. */
    public long getTypeId() { return typeId; }

    /** @return the byte size of one record in this compound layout. */
    public long getTotalSize() { return totalSize; }

    /** Release the compound type id and every variable-length string
     *  aux type id retained during construction. Idempotent. */
    @Override
    public void close() {
        if (closed) return;
        for (long tid : auxTypeIds) {
            try { H5.H5Tclose(tid); } catch (Exception ignored) {}
        }
        auxTypeIds.clear();
        if (typeId >= 0) {
            try { H5.H5Tclose(typeId); } catch (Exception ignored) {}
            typeId = -1;
        }
        closed = true;
    }
}
