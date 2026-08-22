/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

/**
 * In-memory storage provider. URLs look like {@code memory://<name>};
 * opening the same name twice returns the same tree until
 * {@link #discardStore(String)} clears it.
 *
 * <p>Exists to prove the abstraction works: if
 * {@code SpectralDataset} reads and writes identically over
 * {@link Hdf5Provider} and {@code MemoryProvider}, the interface is
 * correct.</p>
 *
 * <p>API status: Stable.</p>
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code TTIOMemoryProvider}</li>
 *   <li>Python: {@code ttio.providers.memory.MemoryProvider}</li>
 * </ul>
 *
 *
 */
public final class MemoryProvider implements StorageProvider {

    private static final Map<String, MemGroup> STORES = new ConcurrentHashMap<>();

    private String url;
    private MemGroup root;
    private boolean open;

    /** No-arg constructor for ServiceLoader. */
    public MemoryProvider() {}

    @Override
    public String providerName() { return "memory"; }

    @Override
    public boolean supportsUrl(String pathOrUrl) {
        return pathOrUrl.startsWith("memory://");
    }

    @Override
    public StorageProvider open(String pathOrUrl, Mode mode) {
        String key = normaliseUrl(pathOrUrl);
        switch (mode) {
            case CREATE -> STORES.put(key, new MemGroup("/"));
            case READ -> {
                if (!STORES.containsKey(key)) {
                    throw new IllegalArgumentException(
                            "memory store not found: " + key);
                }
            }
            case READ_WRITE, APPEND -> STORES.computeIfAbsent(key, k -> new MemGroup("/"));
        }
        this.url = key;
        this.root = STORES.get(key);
        this.open = true;
        return this;
    }

    @Override
    public StorageGroup rootGroup() {
        requireOpen();
        return root;
    }

    @Override
    public boolean isOpen() { return open; }

    @Override
    public void close() { open = false; }

    public static void discardStore(String pathOrUrl) {
        STORES.remove(normaliseUrl(pathOrUrl));
    }

    private void requireOpen() {
        if (!open) throw new IllegalStateException("provider closed");
    }

    private static String normaliseUrl(String s) {
        return s.startsWith("memory://") ? s : "memory://" + s;
    }

    // ── Group impl ──────────────────────────────────────────────

    static final class MemGroup implements StorageGroup {
        private final String name;
        private final Map<String, MemGroup> groups = new LinkedHashMap<>();
        private final Map<String, MemDataset> datasets = new LinkedHashMap<>();
        private final Map<String, Object> attrs = new LinkedHashMap<>();

        MemGroup(String name) { this.name = name; }

        @Override public String name() { return name; }

        @Override public List<String> childNames() {
            List<String> out = new ArrayList<>(groups.keySet());
            out.addAll(datasets.keySet());
            return out;
        }

        @Override public boolean hasChild(String n) {
            return groups.containsKey(n) || datasets.containsKey(n);
        }

        @Override public StorageGroup openGroup(String n) {
            MemGroup g = groups.get(n);
            if (g == null) throw new NoSuchElementException("no group: " + n);
            return g;
        }

        @Override public StorageGroup createGroup(String n) {
            if (hasChild(n)) throw new IllegalArgumentException("exists: " + n);
            MemGroup g = new MemGroup(n);
            groups.put(n, g);
            return g;
        }

        @Override public void deleteChild(String n) {
            groups.remove(n);
            datasets.remove(n);
        }

        @Override public StorageDataset openDataset(String n) {
            MemDataset d = datasets.get(n);
            if (d == null) throw new NoSuchElementException("no dataset: " + n);
            return d;
        }

        @Override
        public StorageDataset createDataset(String n, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel) {
            return createDataset(n, precision, length, chunkSize, compression,
                                  compressionLevel, false);
        }

        @Override
        public StorageDataset createDataset(String n, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel,
                                             boolean extendable) {
            StorageGroup.requireChunkForExtendable(extendable, chunkSize);
            if (hasChild(n)) throw new IllegalArgumentException("exists: " + n);
            long[] chunks = chunkSize > 0 ? new long[]{chunkSize} : null;
            MemDataset d = new MemDataset(n, precision, new long[]{length},
                                            chunks, null, extendable);
            datasets.put(n, d);
            return d;
        }

        @Override
        public StorageDataset createDatasetND(String n, Precision precision,
                                                long[] shape, long[] chunks,
                                                Compression compression,
                                                int compressionLevel) {
            if (hasChild(n)) throw new IllegalArgumentException("exists: " + n);
            MemDataset d = new MemDataset(n, precision, shape.clone(),
                                            chunks != null ? chunks.clone() : null,
                                            null);
            datasets.put(n, d);
            return d;
        }

        @Override
        public StorageDataset createCompoundDataset(String n,
                                                     List<CompoundField> fields,
                                                     long count) {
            return createCompoundDataset(n, fields, count, false, 0);
        }

        @Override
        public StorageDataset createCompoundDataset(String n,
                                                     List<CompoundField> fields,
                                                     long count,
                                                     boolean extendable,
                                                     int chunkRows) {
            StorageGroup.requireChunkForExtendable(extendable, chunkRows);
            if (hasChild(n)) throw new IllegalArgumentException("exists: " + n);
            MemDataset d = new MemDataset(n, null, new long[]{count}, null,
                                            List.copyOf(fields), extendable);
            datasets.put(n, d);
            return d;
        }

        @Override public boolean hasAttribute(String n) { return attrs.containsKey(n); }
        @Override public Object getAttribute(String n) { return attrs.get(n); }
        @Override public void setAttribute(String n, Object v) { attrs.put(n, v); }
        @Override public void deleteAttribute(String n) { attrs.remove(n); }
        @Override public List<String> attributeNames() { return new ArrayList<>(attrs.keySet()); }
    }

    // ── Dataset impl ─────────────────────────────────────────────

    static final class MemDataset implements StorageDataset {
        private final String name;
        private final Precision precision;
        private final long[] shape;
        private final long[] chunks;
        private final List<CompoundField> fields;
        private final boolean extendable;
        private Object data;
        /* Appends land here and are joined once, on read. Concatenating
         * on every append made the cost quadratic in the append count. */
        private final List<Object> pending = new ArrayList<>();
        private final Map<String, Object> attrs = new LinkedHashMap<>();

        MemDataset(String name, Precision precision, long[] shape,
                    long[] chunks, List<CompoundField> fields) {
            this(name, precision, shape, chunks, fields, false);
        }

        MemDataset(String name, Precision precision, long[] shape,
                    long[] chunks, List<CompoundField> fields,
                    boolean extendable) {
            this.name = name;
            this.precision = precision;
            this.shape = shape;
            this.chunks = chunks;
            this.fields = fields;
            this.extendable = extendable;
        }

        @Override public String name() { return name; }
        @Override public Precision precision() { return precision; }
        @Override public long[] shape() { return shape.clone(); }
        @Override public long[] chunks() { return chunks == null ? null : chunks.clone(); }
        @Override public List<CompoundField> compoundFields() { return fields; }
        @Override public boolean extendable() { return extendable; }

        /** Join any pending appends into {@code data}. Readers call this. */
        private void materialise() {
            if (pending.isEmpty()) return;
            int n = data == null ? 0 : lengthOf(data);
            for (Object p : pending) n += lengthOf(p);
            Object first = data != null ? data : pending.get(0);
            Object out = java.lang.reflect.Array.newInstance(
                first.getClass().getComponentType(), n);
            int at = 0;
            if (data != null) {
                System.arraycopy(data, 0, out, at, lengthOf(data));
                at += lengthOf(data);
            }
            for (Object p : pending) {
                System.arraycopy(p, 0, out, at, lengthOf(p));
                at += lengthOf(p);
            }
            pending.clear();
            data = out;
        }

        @Override public Object readAll() {
            materialise();
            if (data == null && extendable) {
                return fields != null ? new ArrayList<Object[]>() : emptyArray(precision);
            }
            return data;
        }

        @Override
        @SuppressWarnings("unchecked")
        public void append(Object d) {
            if (!extendable) {
                throw new UnsupportedOperationException(
                    "dataset '" + name + "' is not extendable");
            }
            if (fields != null) {
                List<Object[]> rows = data == null ? new ArrayList<>() : (List<Object[]>) data;
                for (Object o : (List<?>) d) {
                    if (o instanceof Object[] row) {
                        rows.add(row);
                    } else {
                        Map<String, Object> m = (Map<String, Object>) o;
                        Object[] row = new Object[fields.size()];
                        for (int i = 0; i < row.length; i++) row[i] = m.get(fields.get(i).name());
                        rows.add(row);
                    }
                }
                data = rows;
                shape[0] = rows.size();
                return;
            }
            pending.add(copyPrimitive(d));
            long n = data == null ? 0 : lengthOf(data);
            for (Object p : pending) n += lengthOf(p);
            shape[0] = n;
        }

        @Override
        public void writeSlice(long offset, Object d) {
            materialise();
            if (data == null) throw new IllegalStateException("dataset '" + name + "' has no data");
            int n = lengthOf(d);
            if (offset < 0 || offset + n > lengthOf(data)) {
                throw new IndexOutOfBoundsException("writeSlice out of range");
            }
            System.arraycopy(d, 0, data, (int) offset, n);
        }

        private static Object emptyArray(Precision p) {
            return switch (p) {
                case FLOAT32 -> new float[0];
                case FLOAT64, COMPLEX128 -> new double[0];
                case INT32, UINT32 -> new int[0];
                case INT64, UINT64 -> new long[0];
                case UINT16 -> new short[0];
                case UINT8 -> new byte[0];
                case _RESERVED_INT8 -> throw new UnsupportedOperationException("reserved precision");
            };
        }

        private static int lengthOf(Object a) {
            return java.lang.reflect.Array.getLength(a);
        }

        private static Object copyPrimitive(Object a) {
            int n = lengthOf(a);
            Object out = java.lang.reflect.Array.newInstance(a.getClass().getComponentType(), n);
            System.arraycopy(a, 0, out, 0, n);
            return out;
        }

        private static Object concatPrimitive(Object a, Object b) {
            int na = lengthOf(a), nb = lengthOf(b);
            Object out = java.lang.reflect.Array.newInstance(a.getClass().getComponentType(), na + nb);
            System.arraycopy(a, 0, out, 0, na);
            System.arraycopy(b, 0, out, na, nb);
            return out;
        }

        @Override
        public Object readSlice(long offset, long count) {
            materialise();
            if (data == null) return null;
            if (fields != null) {
                @SuppressWarnings("unchecked")
                List<Object[]> rows = (List<Object[]>) data;
                int from = (int) offset;
                int to = (int) Math.min(rows.size(), offset + count);
                return new ArrayList<>(rows.subList(from, to));
            }
            return slicePrimitive(data, (int) offset, (int) count);
        }

        @Override public void writeAll(Object d) { pending.clear(); this.data = d; }

        @Override public boolean hasAttribute(String n) { return attrs.containsKey(n); }
        @Override public Object getAttribute(String n) { return attrs.get(n); }
        @Override public void setAttribute(String n, Object v) { attrs.put(n, v); }
        @Override public void deleteAttribute(String n) { attrs.remove(n); }
        @Override public List<String> attributeNames() { return new ArrayList<>(attrs.keySet()); }

        private static Object slicePrimitive(Object src, int offset, int count) {
            if (src instanceof double[] a) {
                double[] out = new double[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof float[] a) {
                float[] out = new float[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof int[] a) {
                int[] out = new int[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof long[] a) {
                long[] out = new long[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof byte[] a) {
                byte[] out = new byte[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof short[] a) {
                short[] out = new short[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            throw new IllegalStateException(
                    "MemoryProvider slice: unsupported element type "
                    + src.getClass());
        }
    }
}
