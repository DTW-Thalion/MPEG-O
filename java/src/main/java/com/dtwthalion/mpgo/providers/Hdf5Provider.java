/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

import com.dtwthalion.mpgo.Enums.Compression;
import com.dtwthalion.mpgo.Enums.Precision;
import com.dtwthalion.mpgo.hdf5.Hdf5CompoundIO;
import com.dtwthalion.mpgo.hdf5.Hdf5Dataset;
import com.dtwthalion.mpgo.hdf5.Hdf5File;
import com.dtwthalion.mpgo.hdf5.Hdf5Group;
import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

import java.util.*;
import java.util.stream.Collectors;

/**
 * HDF5 storage provider. Adapter over the existing {@link Hdf5File}
 * / {@link Hdf5Group} / {@link Hdf5Dataset} layer — no behavioural
 * change; callers that used those directly can switch to
 * {@code Hdf5Provider.open(path, Mode.READ)} and continue.
 *
 * <p>API status: Stable (Provisional per M39 — may change before v1.0).</p>
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code MPGOHDF5Provider}</li>
 *   <li>Python: {@code mpeg_o.providers.hdf5.Hdf5Provider}</li>
 * </ul>
 *
 * @since 0.6
 */
public final class Hdf5Provider implements StorageProvider {

    private Hdf5File file;
    private boolean open;

    /** No-arg constructor for ServiceLoader. */
    public Hdf5Provider() {}

    @Override
    public String providerName() { return "hdf5"; }

    @Override
    public boolean supportsUrl(String pathOrUrl) {
        if (pathOrUrl.startsWith("memory://")) return false;
        if (pathOrUrl.startsWith("file://")) return true;
        return !pathOrUrl.contains("://"); // bare path
    }

    @Override
    public StorageProvider open(String pathOrUrl, Mode mode) {
        String path = pathOrUrl.startsWith("file://")
                ? pathOrUrl.substring("file://".length())
                : pathOrUrl;
        this.file = switch (mode) {
            case CREATE -> Hdf5File.create(path);
            case READ -> Hdf5File.openReadOnly(path);
            case READ_WRITE, APPEND -> Hdf5File.open(path);
        };
        this.open = true;
        return this;
    }

    @Override
    public StorageGroup rootGroup() {
        if (!open) throw new IllegalStateException("provider closed");
        return new Hdf5GroupAdapter(file.rootGroup(), /*ownsNative=*/true);
    }

    @Override
    public boolean isOpen() { return open; }

    @Override
    public Object nativeHandle() { return file; }

    @Override
    public void close() {
        if (file != null) file.close();
        open = false;
    }

    // ── Group adapter ───────────────────────────────────────────

    static final class Hdf5GroupAdapter implements StorageGroup {
        private final Hdf5Group delegate;
        private final boolean ownsNative;

        Hdf5GroupAdapter(Hdf5Group delegate, boolean ownsNative) {
            this.delegate = delegate;
            this.ownsNative = ownsNative;
        }

        Hdf5Group unwrap() { return delegate; }

        @Override public String name() { return delegate.name(); }

        @Override public List<String> childNames() {
            return delegate.childNames();
        }

        @Override public boolean hasChild(String name) {
            return delegate.hasChild(name);
        }

        @Override public StorageGroup openGroup(String name) {
            return new Hdf5GroupAdapter(delegate.openGroup(name), true);
        }

        @Override public StorageGroup createGroup(String name) {
            return new Hdf5GroupAdapter(delegate.createGroup(name), true);
        }

        @Override public void deleteChild(String name) {
            delegate.deleteChild(name);
        }

        @Override public StorageDataset openDataset(String name) {
            // Probe the on-disk type: compound-with-VL needs the
            // Hdf5CompoundIO projection path, primitive goes via
            // Hdf5Dataset directly.
            Hdf5CompoundIO.Schema schema = tryReadCompoundSchema(
                    delegate.getGroupId(), name);
            if (schema != null) {
                int len = (int) readDatasetLength(delegate.getGroupId(), name);
                return new Hdf5CompoundDatasetAdapter(delegate, name, schema, len);
            }
            return new Hdf5DatasetAdapter(delegate.openDataset(name), name);
        }

        @Override
        public StorageDataset createDataset(String name, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel) {
            Hdf5Dataset ds = (compression == Compression.NONE && chunkSize <= 0)
                    ? delegate.createDataset(name, precision, (int) length, 0, 0)
                    : delegate.createDataset(name, precision, (int) length,
                                              chunkSize, compression,
                                              compressionLevel);
            return new Hdf5DatasetAdapter(ds, name);
        }

        @Override
        public StorageDataset createCompoundDataset(String name,
                                                     List<CompoundField> fields,
                                                     long count) {
            Hdf5CompoundIO.Schema schema = toSchema(fields);
            // Delegate actual write to Hdf5CompoundIO.writeCompoundDataset
            // when the caller supplies data via a packer. At create-time
            // we only need the handle so we can expose metadata; the
            // actual H5Dcreate happens when writeAll is called below.
            return new Hdf5CompoundDatasetAdapter(delegate, name, schema, (int) count);
        }

        @Override public boolean hasAttribute(String name) {
            return delegate.hasAttribute(name);
        }

        @Override public Object getAttribute(String name) {
            // Strings and longs are the two shapes MPEG-O uses today.
            if (delegate.hasAttribute(name)) {
                try { return delegate.readStringAttribute(name); }
                catch (Exception ignored) {}
                try { return delegate.readIntegerAttribute(name, 0L); }
                catch (Exception ignored) {}
            }
            return null;
        }

        @Override public void setAttribute(String name, Object value) {
            if (value instanceof String s) {
                delegate.setStringAttribute(name, s);
            } else if (value instanceof Number n) {
                delegate.setIntegerAttribute(name, n.longValue());
            } else if (value == null) {
                deleteAttribute(name);
            } else {
                throw new UnsupportedOperationException(
                        "attribute value type not supported: " + value.getClass());
            }
        }

        @Override public void deleteAttribute(String name) {
            delegate.deleteAttribute(name);
        }

        @Override public List<String> attributeNames() {
            return delegate.attributeNames();
        }

        @Override public void close() {
            if (ownsNative) delegate.close();
        }
    }

    // ── Primitive dataset adapter ───────────────────────────────

    static final class Hdf5DatasetAdapter implements StorageDataset {
        private final Hdf5Dataset delegate;
        private final String name;

        Hdf5DatasetAdapter(Hdf5Dataset delegate, String name) {
            this.delegate = delegate;
            this.name = name;
        }

        @Override public String name() { return name; }
        @Override public Precision precision() { return delegate.getPrecision(); }
        @Override public long[] shape() { return new long[]{ delegate.getLength() }; }
        @Override public List<CompoundField> compoundFields() { return null; }

        @Override public Object readAll() { return delegate.readData(); }
        @Override public Object readSlice(long offset, long count) {
            return delegate.readData(offset, count);
        }
        @Override public void writeAll(Object data) { delegate.writeData(data); }

        @Override public boolean hasAttribute(String n) { return false; }
        @Override public Object getAttribute(String n) { return null; }
        @Override public void setAttribute(String n, Object v) {
            throw new UnsupportedOperationException(
                    "dataset-level attributes not yet exposed via Hdf5Dataset");
        }

        @Override public void close() { delegate.close(); }
    }

    // ── Compound dataset adapter ────────────────────────────────
    //
    // Lazily materialises the HDF5 compound via Hdf5CompoundIO on
    // the first writeAll(). readAll() delegates to the same helper's
    // projection-read which recovers primitive fields only (Java
    // cannot read VL strings inside a compound under JHI5 1.10 —
    // see format-spec §11.1).

    static final class Hdf5CompoundDatasetAdapter implements StorageDataset {
        private final Hdf5Group parent;
        private final String name;
        private final Hdf5CompoundIO.Schema schema;
        private final int count;
        private boolean written;

        Hdf5CompoundDatasetAdapter(Hdf5Group parent, String name,
                                    Hdf5CompoundIO.Schema schema, int count) {
            this.parent = parent;
            this.name = name;
            this.schema = schema;
            this.count = count;
        }

        @Override public String name() { return name; }
        @Override public Precision precision() { return null; }
        @Override public long[] shape() { return new long[]{ count }; }

        @Override public List<CompoundField> compoundFields() {
            return schema.fields.stream()
                    .map(f -> new CompoundField(f.name(), fromIoKind(f.kind())))
                    .toList();
        }

        @SuppressWarnings("unchecked")
        @Override
        public void writeAll(Object data) {
            List<Object[]> rows = (List<Object[]>) data;
            Hdf5CompoundIO.writeCompoundDataset(parent, name, schema, rows.size(),
                    (row, pool) -> {
                        Object[] vals = rows.get(row);
                        Object[] out = new Object[schema.fields.size()];
                        for (int i = 0; i < schema.fields.size(); i++) {
                            Hdf5CompoundIO.FieldKind k = schema.fields.get(i).kind();
                            out[i] = k == Hdf5CompoundIO.FieldKind.VL_STRING
                                    ? pool.addString((String) vals[i])
                                    : vals[i];
                        }
                        return out;
                    });
            written = true;
        }

        @Override
        public Object readAll() {
            return Hdf5CompoundIO.readCompoundPrimitives(parent, name, schema);
        }

        @Override
        public Object readSlice(long offset, long count) {
            @SuppressWarnings("unchecked")
            List<Object[]> all = (List<Object[]>) readAll();
            int from = (int) offset;
            int to = (int) Math.min(all.size(), offset + count);
            return new ArrayList<>(all.subList(from, to));
        }

        @Override public boolean hasAttribute(String n) { return false; }
        @Override public Object getAttribute(String n) { return null; }
        @Override public void setAttribute(String n, Object v) {
            throw new UnsupportedOperationException(
                    "compound-dataset attributes not yet routed");
        }

        @Override public void close() { /* no per-dataset handle retained */ }

        private static CompoundField.Kind fromIoKind(Hdf5CompoundIO.FieldKind k) {
            return switch (k) {
                case UINT32 -> CompoundField.Kind.UINT32;
                case INT64 -> CompoundField.Kind.INT64;
                case FLOAT64 -> CompoundField.Kind.FLOAT64;
                case VL_STRING -> CompoundField.Kind.VL_STRING;
            };
        }
    }

    // ── Type probing for existing datasets ───────────────────────

    /** Read a dataset's on-disk compound schema, or {@code null} if
     *  the dataset is not a compound. Resources are released before
     *  returning. */
    private static Hdf5CompoundIO.Schema tryReadCompoundSchema(long groupId,
                                                                 String name) {
        long did = -1, ftype = -1;
        try {
            did = H5.H5Dopen(groupId, name, HDF5Constants.H5P_DEFAULT);
            if (did < 0) return null;
            ftype = H5.H5Dget_type(did);
            if (H5.H5Tget_class(ftype) != HDF5Constants.H5T_COMPOUND) {
                return null;
            }
            int n = H5.H5Tget_nmembers(ftype);
            List<Hdf5CompoundIO.Field> fields = new ArrayList<>(n);
            for (int i = 0; i < n; i++) {
                String fname = H5.H5Tget_member_name(ftype, i);
                long mt = H5.H5Tget_member_type(ftype, i);
                try {
                    int cls = H5.H5Tget_class(mt);
                    long size = H5.H5Tget_size(mt);
                    Hdf5CompoundIO.FieldKind kind;
                    if (cls == HDF5Constants.H5T_STRING
                            && H5.H5Tis_variable_str(mt)) {
                        kind = Hdf5CompoundIO.FieldKind.VL_STRING;
                    } else if (cls == HDF5Constants.H5T_INTEGER && size == 4) {
                        kind = Hdf5CompoundIO.FieldKind.UINT32;
                    } else if (cls == HDF5Constants.H5T_INTEGER && size == 8) {
                        kind = Hdf5CompoundIO.FieldKind.INT64;
                    } else if (cls == HDF5Constants.H5T_FLOAT && size == 8) {
                        kind = Hdf5CompoundIO.FieldKind.FLOAT64;
                    } else {
                        return null; // unsupported kind — give up, fall
                                     // back to primitive adapter
                    }
                    fields.add(new Hdf5CompoundIO.Field(fname, kind));
                } finally {
                    try { H5.H5Tclose(mt); } catch (Exception ignored) {}
                }
            }
            return new Hdf5CompoundIO.Schema(fields);
        } catch (HDF5LibraryException e) {
            return null;
        } finally {
            if (ftype >= 0) try { H5.H5Tclose(ftype); } catch (Exception ignored) {}
            if (did >= 0) try { H5.H5Dclose(did); } catch (Exception ignored) {}
        }
    }

    private static long readDatasetLength(long groupId, String name) {
        long did = -1, sid = -1;
        try {
            did = H5.H5Dopen(groupId, name, HDF5Constants.H5P_DEFAULT);
            if (did < 0) return 0;
            sid = H5.H5Dget_space(did);
            long[] dims = { 0 };
            H5.H5Sget_simple_extent_dims(sid, dims, null);
            return dims[0];
        } catch (HDF5LibraryException e) {
            return 0;
        } finally {
            if (sid >= 0) try { H5.H5Sclose(sid); } catch (Exception ignored) {}
            if (did >= 0) try { H5.H5Dclose(did); } catch (Exception ignored) {}
        }
    }

    // ── Schema translation ──────────────────────────────────────

    private static Hdf5CompoundIO.Schema toSchema(List<CompoundField> fields) {
        List<Hdf5CompoundIO.Field> mapped = fields.stream()
                .map(f -> new Hdf5CompoundIO.Field(f.name(), switch (f.kind()) {
                    case UINT32 -> Hdf5CompoundIO.FieldKind.UINT32;
                    case INT64 -> Hdf5CompoundIO.FieldKind.INT64;
                    case FLOAT64 -> Hdf5CompoundIO.FieldKind.FLOAT64;
                    case VL_STRING -> Hdf5CompoundIO.FieldKind.VL_STRING;
                }))
                .collect(Collectors.toList());
        // Package-private Schema constructor is reachable from this package's
        // sibling; reuse via the public static factories on Hdf5CompoundIO.
        return new Hdf5CompoundIO.Schema(mapped);
    }
}
