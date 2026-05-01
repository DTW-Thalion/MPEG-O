/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

/**
 * Thin wrapper around an HDF5 group handle. Created by
 * {@link Hdf5File#rootGroup()} or by another group's
 * {@link #createGroup}/{@link #openGroup}.
 *
 * <p>Non-owning: the parent file's lifetime is retained by every group
 * derived from it. All public methods acquire the appropriate lock from
 * the owning file.</p>
 *
 * @since 0.5
 */
public class Hdf5Group implements AutoCloseable {

    private static final int LZ4_FILTER_ID = 32004;

    private long groupId;
    private final Hdf5File file;
    private boolean closed;

    Hdf5Group(long groupId, Hdf5File file) {
        this.groupId = groupId;
        this.file = file;
        this.closed = false;
    }

    public long getGroupId() { return groupId; }
    public Hdf5File owningFile() { return file; }

    /** Short (last-path-segment) name of this group, or "/" for root. */
    public String name() {
        try {
            String[] buf = new String[1];
            H5.H5Iget_name_long(groupId, buf, 1024);
            String full = buf[0];
            if (full == null || full.isEmpty() || "/".equals(full)) return "/";
            int slash = full.lastIndexOf('/');
            return slash >= 0 && slash < full.length() - 1
                    ? full.substring(slash + 1) : full;
        } catch (HDF5LibraryException e) {
            return "/";
        }
    }

    /** Names of every link (group or dataset) directly under this group. */
    public java.util.List<String> childNames() {
        file.lockForReading();
        try {
            long n = H5.H5Gn_members(groupId, ".");
            java.util.List<String> out = new java.util.ArrayList<>((int) n);
            String[] oname = new String[1];
            int[] otype = new int[1];
            for (int i = 0; i < n; i++) {
                H5.H5Gget_obj_info_idx(groupId, ".", i, oname, otype);
                if (oname[0] != null) out.add(oname[0]);
            }
            return out;
        } catch (HDF5LibraryException e) {
            return java.util.List.of();
        } finally {
            file.unlockForReading();
        }
    }

    // ── Sub-groups ──────────────────────────────────────────────────

    public Hdf5Group createGroup(String name) {
        file.lockForWriting();
        try {
            long gid = H5.H5Gcreate(groupId, name,
                    HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT);
            if (gid < 0) throw new Hdf5Errors.GroupCreateException(name);
            return new Hdf5Group(gid, file);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.GroupCreateException(name);
        } finally {
            file.unlockForWriting();
        }
    }

    public Hdf5Group openGroup(String name) {
        file.lockForReading();
        try {
            long gid = H5.H5Gopen(groupId, name, HDF5Constants.H5P_DEFAULT);
            if (gid < 0) throw new Hdf5Errors.GroupOpenException(name);
            return new Hdf5Group(gid, file);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.GroupOpenException(name);
        } finally {
            file.unlockForReading();
        }
    }

    public boolean hasChild(String name) {
        file.lockForReading();
        try {
            return H5.H5Lexists(groupId, name, HDF5Constants.H5P_DEFAULT);
        } catch (HDF5LibraryException e) {
            return false;
        } finally {
            file.unlockForReading();
        }
    }

    public void deleteChild(String name) {
        file.lockForWriting();
        try {
            if (H5.H5Lexists(groupId, name, HDF5Constants.H5P_DEFAULT)) {
                H5.H5Ldelete(groupId, name, HDF5Constants.H5P_DEFAULT);
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetCreateException(
                    "H5Ldelete failed for '" + name + "'");
        } finally {
            file.unlockForWriting();
        }
    }

    // ── Datasets ────────────────────────────────────────────────────

    /**
     * Create a 1-D dataset with zlib compression at the given level (0=none, 1-9).
     */
    public Hdf5Dataset createDataset(String name, Precision precision,
                                     long length, long chunkSize,
                                     int compressionLevel) {
        return createDataset(name, precision, length, chunkSize,
                Compression.ZLIB, compressionLevel);
    }

    /**
     * Create a 1-D dataset with explicit compression choice.
     */
    public Hdf5Dataset createDataset(String name, Precision precision,
                                     long length, long chunkSize,
                                     Compression compression,
                                     int compressionLevel) {
        file.lockForWriting();
        long space = -1, plist = -1, htype = -1, did = -1;
        try {
            long[] dims = { length };
            space = H5.H5Screate_simple(1, dims, null);
            if (space < 0) throw new Hdf5Errors.DatasetCreateException(
                    "H5Screate_simple failed for '" + name + "'");

            plist = H5.H5Pcreate(HDF5Constants.H5P_DATASET_CREATE);
            if (plist < 0) throw new Hdf5Errors.DatasetCreateException(
                    "H5Pcreate failed for '" + name + "'");

            if (chunkSize > 0 && length > 0) {
                long[] chunk = { Math.min(chunkSize, length) };
                H5.H5Pset_chunk(plist, 1, chunk);
                if (compression == Compression.ZLIB && compressionLevel > 0) {
                    H5.H5Pset_deflate(plist, compressionLevel);
                } else if (compression == Compression.LZ4) {
                    if (H5.H5Zfilter_avail(LZ4_FILTER_ID) <= 0) {
                        throw new Hdf5Errors.DatasetCreateException(
                                "LZ4 filter (id 32004) is not available; " +
                                "install the hdf5plugin package or set HDF5_PLUGIN_PATH");
                    }
                    H5.H5Pset_filter(plist, LZ4_FILTER_ID,
                            HDF5Constants.H5Z_FLAG_MANDATORY, 0, null);
                }
            }

            htype = hdf5TypeFor(precision);
            did = H5.H5Dcreate(groupId, name, htype, space,
                    HDF5Constants.H5P_DEFAULT, plist, HDF5Constants.H5P_DEFAULT);
            if (did < 0) throw new Hdf5Errors.DatasetCreateException(
                    "H5Dcreate2 failed for '" + name + "'");

            return new Hdf5Dataset(did, precision, length, file);
        } catch (HDF5LibraryException e) {
            if (did >= 0) try { H5.H5Dclose(did); } catch (Exception ignored) {}
            throw new Hdf5Errors.DatasetCreateException(
                    "H5Dcreate failed for '" + name + "': " + e.getMessage());
        } finally {
            if (precision == Precision.COMPLEX128 && htype >= 0)
                try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            if (plist >= 0) try { H5.H5Pclose(plist); } catch (Exception ignored) {}
            if (space >= 0) try { H5.H5Sclose(space); } catch (Exception ignored) {}
            file.unlockForWriting();
        }
    }

    public Hdf5Dataset openDataset(String name) {
        file.lockForReading();
        try {
            long did = H5.H5Dopen(groupId, name, HDF5Constants.H5P_DEFAULT);
            if (did < 0) throw new Hdf5Errors.DatasetOpenException(name);

            long space = H5.H5Dget_space(did);
            long[] dims = new long[1];
            H5.H5Sget_simple_extent_dims(space, dims, null);
            H5.H5Sclose(space);

            long htid = H5.H5Dget_type(did);
            Precision precision = precisionFromType(htid);
            H5.H5Tclose(htid);

            return new Hdf5Dataset(did, precision, dims[0], file);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetOpenException(name);
        } finally {
            file.unlockForReading();
        }
    }

    // ── Attributes ──────────────────────────────────────────────────

    public void setStringAttribute(String name, String value) {
        // M90.7: write as VL_STRING with UTF-8 encoding (matches what
        // h5py writes by default), so Python readers can verify
        // signatures and other string attributes written by Java.
        // The pre-M90.7 fixed-length path was ASCII-only and reported
        // a non-VARIABLE type to other-language readers, breaking
        // cross-language compat on @ttio_signature etc.
        file.lockForWriting();
        long htype = -1, space = -1, aid = -1;
        try {
            htype = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(htype, HDF5Constants.H5T_VARIABLE);
            H5.H5Tset_strpad(htype, HDF5Constants.H5T_STR_NULLTERM);
            H5.H5Tset_cset(htype, HDF5Constants.H5T_CSET_UTF8);

            space = H5.H5Screate(HDF5Constants.H5S_SCALAR);

            if (H5.H5Aexists(groupId, name)) {
                H5.H5Adelete(groupId, name);
            }

            aid = H5.H5Acreate(groupId, name, htype, space,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) throw new Hdf5Errors.AttributeException(
                    "H5Acreate2 failed for '" + name + "'");

            String[] data = { value };
            H5.H5Awrite_VLStrings(aid, htype, data);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "setStringAttribute failed for '" + name + "': " + e.getMessage());
        } finally {
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            if (space >= 0) try { H5.H5Sclose(space); } catch (Exception ignored) {}
            if (htype >= 0) try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            file.unlockForWriting();
        }
    }

    public String readStringAttribute(String name) {
        // M90.7: read both VL_STRING (forward) and fixed-length
        // (pre-M90.7 + cross-platform back-compat) string attributes.
        file.lockForReading();
        long aid = -1, htype = -1;
        try {
            if (!H5.H5Aexists(groupId, name)) {
                throw new Hdf5Errors.AttributeException(
                        "attribute '" + name + "' does not exist");
            }
            aid = H5.H5Aopen(groupId, name, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) throw new Hdf5Errors.AttributeException(
                    "H5Aopen failed for '" + name + "'");

            htype = H5.H5Aget_type(aid);
            if (H5.H5Tis_variable_str(htype)) {
                String[] buf = new String[1];
                H5.H5Aread_VLStrings(aid, htype, buf);
                return buf[0] == null ? "" : buf[0];
            }
            // Back-compat: fixed-length string.
            long size = H5.H5Tget_size(htype);
            byte[] buf = new byte[(int) size];
            H5.H5Aread(aid, htype, buf);
            int end = buf.length;
            while (end > 0 && buf[end - 1] == 0) end--;
            return new String(buf, 0, end, java.nio.charset.StandardCharsets.UTF_8);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "readStringAttribute failed for '" + name + "': " + e.getMessage());
        } finally {
            if (htype >= 0) try { H5.H5Tclose(htype); } catch (Exception ignored) {}
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            file.unlockForReading();
        }
    }

    public void setIntegerAttribute(String name, long value) {
        file.lockForWriting();
        long space = -1, aid = -1;
        try {
            space = H5.H5Screate(HDF5Constants.H5S_SCALAR);
            if (H5.H5Aexists(groupId, name)) {
                H5.H5Adelete(groupId, name);
            }
            aid = H5.H5Acreate(groupId, name, HDF5Constants.H5T_NATIVE_INT64,
                    space, HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) throw new Hdf5Errors.AttributeException(
                    "H5Acreate2 (int) failed for '" + name + "'");

            long[] data = { value };
            H5.H5Awrite(aid, HDF5Constants.H5T_NATIVE_INT64, data);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "setIntegerAttribute failed for '" + name + "': " + e.getMessage());
        } finally {
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            if (space >= 0) try { H5.H5Sclose(space); } catch (Exception ignored) {}
            file.unlockForWriting();
        }
    }

    /**
     * Read an integer attribute. Returns the value, or {@code defaultValue}
     * if the attribute does not exist.
     */
    public long readIntegerAttribute(String name, long defaultValue) {
        file.lockForReading();
        long aid = -1;
        try {
            if (!H5.H5Aexists(groupId, name)) {
                return defaultValue;
            }
            aid = H5.H5Aopen(groupId, name, HDF5Constants.H5P_DEFAULT);
            if (aid < 0) return defaultValue;

            long[] data = new long[1];
            H5.H5Aread(aid, HDF5Constants.H5T_NATIVE_INT64, data);
            return data[0];
        } catch (HDF5LibraryException e) {
            return defaultValue;
        } finally {
            if (aid >= 0) try { H5.H5Aclose(aid); } catch (Exception ignored) {}
            file.unlockForReading();
        }
    }

    public boolean hasAttribute(String name) {
        file.lockForReading();
        try {
            return H5.H5Aexists(groupId, name);
        } catch (HDF5LibraryException e) {
            return false;
        } finally {
            file.unlockForReading();
        }
    }

    public void deleteAttribute(String name) {
        file.lockForWriting();
        try {
            if (H5.H5Aexists(groupId, name)) {
                H5.H5Adelete(groupId, name);
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.AttributeException(
                    "H5Adelete failed for '" + name + "': " + e.getMessage());
        } finally {
            file.unlockForWriting();
        }
    }

    public java.util.List<String> attributeNames() {
        file.lockForReading();
        try {
            int n = (int) H5.H5Oget_info(groupId).num_attrs;
            java.util.List<String> out = new java.util.ArrayList<>(n);
            for (int i = 0; i < n; i++) {
                long aid = H5.H5Aopen_by_idx(groupId, ".",
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

    @Override
    public void close() {
        if (closed) return;
        try {
            H5.H5Gclose(groupId);
        } catch (HDF5LibraryException ignored) {}
        closed = true;
    }

    // ── Internal helpers ────────────────────────────────────────────

    /**
     * Build the HDF5 type id for a given Precision. For COMPLEX128, creates
     * a compound type {double re; double im;} — caller must close if not builtin.
     *
     * <p>Appendix B Gap 7: HDF5Constants references live here rather
     * than on Precision itself so non-HDF5 providers (SQLite) can load
     * Precision without pulling the HDF5 JNI classes onto the
     * classpath.</p>
     */
    static long hdf5TypeFor(Precision precision) throws HDF5LibraryException {
        return switch (precision) {
            case FLOAT32 -> HDF5Constants.H5T_NATIVE_FLOAT;
            case FLOAT64 -> HDF5Constants.H5T_NATIVE_DOUBLE;
            case INT32   -> HDF5Constants.H5T_NATIVE_INT32;
            case INT64   -> HDF5Constants.H5T_NATIVE_INT64;
            case UINT32  -> HDF5Constants.H5T_NATIVE_UINT32;
            case UINT16  -> HDF5Constants.H5T_NATIVE_UINT16;  // L1: chromosome_ids
            case UINT8   -> HDF5Constants.H5T_NATIVE_UINT8;
            case UINT64  -> HDF5Constants.H5T_NATIVE_UINT64;
            case _RESERVED_INT8 ->
                throw new UnsupportedOperationException(
                    "Precision " + precision + " is reserved (cross-lang parity)");
            case COMPLEX128 -> {
                // Compound {double re; double im} — caller is responsible
                // for H5Tclose() on the returned non-builtin id.
                long tid = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, 16);
                H5.H5Tinsert(tid, "re", 0, HDF5Constants.H5T_NATIVE_DOUBLE);
                H5.H5Tinsert(tid, "im", 8, HDF5Constants.H5T_NATIVE_DOUBLE);
                yield tid;
            }
        };
    }

    static Precision precisionFromType(long htid) throws HDF5LibraryException {
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_FLOAT))
            return Precision.FLOAT32;
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_DOUBLE))
            return Precision.FLOAT64;
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_INT32))
            return Precision.INT32;
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_INT64))
            return Precision.INT64;
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_UINT32))
            return Precision.UINT32;
        // v0.11 M82: round-trip H5T_NATIVE_UINT64 as Precision.UINT64
        // (was Precision.INT64 as a pre-M82 workaround when the enum
        // value didn't exist). Pre-M82 spectrum_index/offsets files
        // written as INT64 by the legacy ObjC writer continue to read
        // back as INT64 — same on-disk bytes; only the precision
        // metadata differs.
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_UINT64))
            return Precision.UINT64;
        // L1 (Task #82 Phase B.1): H5T_NATIVE_UINT16 is the on-disk
        // type for genomic_index/chromosome_ids.
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_UINT16))
            return Precision.UINT16;
        // v0.11 M79: H5T_NATIVE_UINT8 is the on-disk type for genomic
        // base/quality byte arrays.
        if (H5.H5Tequal(htid, HDF5Constants.H5T_NATIVE_UINT8))
            return Precision.UINT8;
        // Check for compound with size == 16 (complex128)
        if ((int) H5.H5Tget_class(htid) == HDF5Constants.H5T_COMPOUND
                && H5.H5Tget_size(htid) == 16) {
            return Precision.COMPLEX128;
        }
        return Precision.FLOAT64; // fallback
    }
}
