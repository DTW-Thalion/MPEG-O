/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
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
 * <p>API status: Stable (Provisional per M39 — may change before v1.0).</p>
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code TTIOMemoryProvider}</li>
 *   <li>Python: {@code ttio.providers.memory.MemoryProvider}</li>
 * </ul>
 *
 * @since 0.6
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
            if (hasChild(n)) throw new IllegalArgumentException("exists: " + n);
            long[] chunks = chunkSize > 0 ? new long[]{chunkSize} : null;
            MemDataset d = new MemDataset(n, precision, new long[]{length},
                                            chunks, null);
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
            if (hasChild(n)) throw new IllegalArgumentException("exists: " + n);
            MemDataset d = new MemDataset(n, null, new long[]{count}, null,
                                            List.copyOf(fields));
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
        private Object data;
        private final Map<String, Object> attrs = new LinkedHashMap<>();

        MemDataset(String name, Precision precision, long[] shape,
                    long[] chunks, List<CompoundField> fields) {
            this.name = name;
            this.precision = precision;
            this.shape = shape;
            this.chunks = chunks;
            this.fields = fields;
        }

        @Override public String name() { return name; }
        @Override public Precision precision() { return precision; }
        @Override public long[] shape() { return shape.clone(); }
        @Override public long[] chunks() { return chunks == null ? null : chunks.clone(); }
        @Override public List<CompoundField> compoundFields() { return fields; }

        @Override public Object readAll() { return data; }

        @Override
        public Object readSlice(long offset, long count) {
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

        @Override public void writeAll(Object d) { this.data = d; }

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
            throw new IllegalStateException(
                    "MemoryProvider slice: unsupported element type "
                    + src.getClass());
        }
    }
}
