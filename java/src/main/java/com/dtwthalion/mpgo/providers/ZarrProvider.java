/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

import com.dtwthalion.mpgo.Enums.Compression;
import com.dtwthalion.mpgo.Enums.Precision;
import com.dtwthalion.mpgo.MiniJson;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;

/**
 * Zarr v2 storage provider — v0.8 M52.
 *
 * <p>Self-contained DirectoryStore implementation — no external zarr
 * library required. The on-disk layout is the Zarr v2 convention
 * (<a href="https://zarr.readthedocs.io/en/stable/spec/v2.html">spec</a>):
 * each group is a directory containing a {@code .zgroup} metadata
 * file, each array is a directory with a {@code .zarray} metadata
 * file plus one chunk file per chunk index, and attributes live in
 * sibling {@code .zattrs} files. Matches the on-disk layout the
 * Python {@code mpeg_o.providers.zarr.ZarrProvider} produces, so
 * Python, Java, and Objective-C can cross-read one another's stores.</p>
 *
 * <p>Compound datasets (HDF5-style records) have no native Zarr
 * representation. This provider (like the Python reference) stores
 * them as sub-groups carrying three special attributes:</p>
 * <ul>
 *   <li>{@code _mpgo_kind = "compound"}</li>
 *   <li>{@code _mpgo_schema = JSON list of {name, kind}}</li>
 *   <li>{@code _mpgo_rows   = JSON list of row dicts}</li>
 *   <li>{@code _mpgo_count  = number}</li>
 * </ul>
 *
 * <p>Scope of this v0.8 port:</p>
 * <ul>
 *   <li>URL schemes: {@code zarr:///abs/path}, bare paths. In-memory
 *       and cloud (S3) stores are Python-only today; v0.9.</li>
 *   <li>Compression: only {@link Compression#NONE} is written and
 *       expected on read. Compressed chunks in Python-authored stores
 *       raise {@link UnsupportedOperationException}.</li>
 *   <li>Primitive types: {@link Precision#FLOAT64}, {@link
 *       Precision#FLOAT32}, {@link Precision#INT64}, {@link
 *       Precision#INT32}, {@link Precision#UINT32}.</li>
 *   <li>Byte order: little-endian only (matches the canonical
 *       transcript used by signatures and encryption).</li>
 * </ul>
 *
 * <p>API status: Provisional (v0.8 M52).</p>
 *
 * <p>Cross-language equivalents: Python {@code
 * mpeg_o.providers.zarr.ZarrProvider}, Objective-C {@code
 * MPGOZarrProvider}.</p>
 *
 * @since 0.8
 */
public final class ZarrProvider implements StorageProvider {

    private Path rootDir;
    private boolean open;
    private Mode mode;

    /** No-arg constructor for ServiceLoader. */
    public ZarrProvider() {}

    @Override
    public String providerName() { return "zarr"; }

    @Override
    public boolean supportsUrl(String pathOrUrl) {
        return pathOrUrl.startsWith("zarr://") || pathOrUrl.endsWith(".zarr");
    }

    @Override
    public StorageProvider open(String pathOrUrl, Mode mode) {
        if (open) throw new IllegalStateException("provider already open");
        this.rootDir = pathForUrl(pathOrUrl);
        this.mode = mode;
        try {
            switch (mode) {
                case CREATE -> {
                    if (Files.exists(rootDir)) {
                        deleteRecursive(rootDir);
                    }
                    Files.createDirectories(rootDir);
                    writeZGroup(rootDir);
                }
                case READ -> {
                    if (!Files.exists(rootDir.resolve(".zgroup"))) {
                        throw new IllegalArgumentException(
                                "zarr store not found: " + rootDir);
                    }
                }
                case READ_WRITE, APPEND -> {
                    if (!Files.exists(rootDir)) {
                        Files.createDirectories(rootDir);
                    }
                    if (!Files.exists(rootDir.resolve(".zgroup"))) {
                        writeZGroup(rootDir);
                    }
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("ZarrProvider open failed: " + rootDir, e);
        }
        this.open = true;
        return this;
    }

    @Override
    public StorageGroup rootGroup() {
        requireOpen();
        return new ZGroup("/", rootDir);
    }

    @Override
    public boolean isOpen() { return open; }

    @Override
    public void close() { open = false; }

    @Override
    public boolean supportsChunking() { return true; }

    @Override
    public boolean supportsCompression() { return false; /* not in v0.8 */ }

    @Override
    public Object nativeHandle() { return rootDir; }

    private void requireOpen() {
        if (!open) throw new IllegalStateException("provider closed");
    }

    // ── URL routing ──────────────────────────────────────────────────────

    static Path pathForUrl(String url) {
        String raw = url;
        if (raw.startsWith("zarr://")) {
            raw = raw.substring("zarr://".length());
            // zarr:/// collapses to an absolute path
            while (raw.startsWith("/") && raw.length() > 1 && raw.charAt(1) == '/') {
                raw = raw.substring(1);
            }
        }
        if (raw.startsWith("zarr+memory://") || raw.startsWith("zarr+s3://")) {
            throw new UnsupportedOperationException(
                    "ZarrProvider (Java): in-memory and S3 stores are "
                    + "Python-only in v0.8 (M52 scope). Got: " + url);
        }
        return Paths.get(raw);
    }

    // ── Zarr v2 metadata writers ─────────────────────────────────────────

    private static final String KIND_ATTR   = "_mpgo_kind";
    private static final String SCHEMA_ATTR = "_mpgo_schema";
    private static final String ROWS_ATTR   = "_mpgo_rows";
    private static final String COUNT_ATTR  = "_mpgo_count";
    private static final String COMPOUND_KIND = "compound";

    static void writeZGroup(Path dir) throws IOException {
        Files.writeString(dir.resolve(".zgroup"), "{\"zarr_format\":2}",
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }

    static void writeZArray(Path dir, long[] shape, long[] chunks,
                             Precision precision) throws IOException {
        String dtype = dtypeFor(precision);
        StringBuilder sb = new StringBuilder();
        sb.append("{");
        sb.append("\"chunks\":").append(jsonLongArray(chunks)).append(",");
        sb.append("\"compressor\":null,");
        sb.append("\"dtype\":\"").append(dtype).append("\",");
        sb.append("\"fill_value\":0,");
        sb.append("\"filters\":null,");
        sb.append("\"order\":\"C\",");
        sb.append("\"shape\":").append(jsonLongArray(shape)).append(",");
        sb.append("\"zarr_format\":2");
        sb.append("}");
        Files.writeString(dir.resolve(".zarray"), sb.toString(),
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }

    static Map<String, Object> readZArray(Path dir) throws IOException {
        String raw = Files.readString(dir.resolve(".zarray"));
        Object parsed = MiniJson.parse(raw);
        if (!(parsed instanceof Map<?, ?> m)) {
            throw new IOException("malformed .zarray: " + dir);
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> out = (Map<String, Object>) m;
        return out;
    }

    static void writeZAttrs(Path dir, Map<String, Object> attrs) throws IOException {
        if (attrs.isEmpty()) {
            Files.deleteIfExists(dir.resolve(".zattrs"));
            return;
        }
        String json = MiniJson.serialise(attrs);
        Files.writeString(dir.resolve(".zattrs"), json,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }

    static Map<String, Object> readZAttrs(Path dir) throws IOException {
        Path p = dir.resolve(".zattrs");
        if (!Files.exists(p)) return new LinkedHashMap<>();
        Object parsed = MiniJson.parse(Files.readString(p));
        if (parsed instanceof Map<?, ?> m) {
            @SuppressWarnings("unchecked")
            Map<String, Object> cast = (Map<String, Object>) m;
            return new LinkedHashMap<>(cast);
        }
        return new LinkedHashMap<>();
    }

    // ── Dtype mapping ───────────────────────────────────────────────────

    static String dtypeFor(Precision p) {
        return switch (p) {
            case FLOAT64 -> "<f8";
            case FLOAT32 -> "<f4";
            case INT64   -> "<i8";
            case INT32   -> "<i4";
            case UINT32  -> "<u4";
            case COMPLEX128 -> throw new UnsupportedOperationException(
                    "ZarrProvider: complex128 not supported");
        };
    }

    static Precision precisionFor(String dtype) {
        return switch (dtype) {
            case "<f8", "|f8", "float64" -> Precision.FLOAT64;
            case "<f4", "|f4", "float32" -> Precision.FLOAT32;
            case "<i8", "|i8", "int64"   -> Precision.INT64;
            case "<i4", "|i4", "int32"   -> Precision.INT32;
            case "<u4", "|u4", "uint32"  -> Precision.UINT32;
            default -> throw new UnsupportedOperationException(
                    "ZarrProvider: unsupported dtype " + dtype);
        };
    }

    /** v0.9: return the numcodecs id string from a compressor spec,
     *  or null if the spec is null. Accepts the Map shape emitted by
     *  numcodecs / parsed back by {@code readZArray}. */
    static String compressorId(Object spec) {
        if (spec == null) return null;
        if (spec instanceof Map<?, ?> m && m.get("id") != null) {
            return m.get("id").toString();
        }
        return spec.toString();
    }

    /** v0.9: decompress a zarr v2 chunk. Supports ``null`` (identity)
     *  and ``{"id":"zlib"}`` (JDK Inflater). Other codecs raise.
     *
     *  Python's ``numcodecs.Zlib`` emits raw zlib (with 2-byte header
     *  + Adler-32 trailer) — the JDK {@code Inflater} default mode
     *  handles that directly. */
    static byte[] decompressChunk(Object spec, byte[] raw, int expectedBytes) {
        if (spec == null) return raw;
        String id = compressorId(spec);
        if ("zlib".equals(id)) {
            java.util.zip.Inflater inflater = new java.util.zip.Inflater();
            inflater.setInput(raw);
            try {
                byte[] out = new byte[expectedBytes];
                int pos = 0;
                while (!inflater.finished() && pos < out.length) {
                    int n = inflater.inflate(out, pos, out.length - pos);
                    if (n == 0 && inflater.needsInput()) break;
                    pos += n;
                }
                if (pos < out.length) {
                    // short read — return what we got zero-padded to full
                    return out;
                }
                return out;
            } catch (java.util.zip.DataFormatException e) {
                throw new RuntimeException("zarr zlib inflate failed", e);
            } finally {
                inflater.end();
            }
        }
        throw new UnsupportedOperationException(
                "zarr compressor '" + id + "' not supported by Java ZarrProvider");
    }

    static int bytesPerElement(Precision p) {
        return switch (p) {
            case FLOAT64, INT64 -> 8;
            case FLOAT32, INT32, UINT32 -> 4;
            case COMPLEX128 -> 16;
        };
    }

    // ── Recursive delete (for Mode.CREATE) ──────────────────────────────

    static void deleteRecursive(Path dir) throws IOException {
        if (!Files.exists(dir)) return;
        try (Stream<Path> walk = Files.walk(dir)) {
            walk.sorted(Comparator.reverseOrder())
                .forEach(p -> {
                    try { Files.delete(p); } catch (IOException ignored) {}
                });
        }
    }

    // ── Helpers for chunked read/write ──────────────────────────────────

    static String jsonLongArray(long[] a) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < a.length; i++) {
            if (i > 0) sb.append(",");
            sb.append(a[i]);
        }
        sb.append("]");
        return sb.toString();
    }

    static long[] readLongArray(Object obj) {
        if (obj instanceof List<?> l) {
            long[] out = new long[l.size()];
            for (int i = 0; i < l.size(); i++) {
                out[i] = ((Number) l.get(i)).longValue();
            }
            return out;
        }
        throw new IllegalArgumentException("expected JSON list of numbers");
    }

    // ────────────────────────────────────────────────────────────────────
    // Group implementation
    // ────────────────────────────────────────────────────────────────────

    static final class ZGroup implements StorageGroup {
        private final String name;
        private final Path dir;

        ZGroup(String name, Path dir) {
            this.name = name;
            this.dir = dir;
        }

        @Override public String name() { return name; }

        @Override
        public List<String> childNames() {
            List<String> out = new ArrayList<>();
            try {
                if (!Files.isDirectory(dir)) return out;
                try (Stream<Path> entries = Files.list(dir)) {
                    entries.forEach(p -> {
                        String n = p.getFileName().toString();
                        if (n.startsWith(".")) return;
                        if (Files.isDirectory(p)) out.add(n);
                    });
                }
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            return out;
        }

        @Override
        public boolean hasChild(String name) {
            return Files.isDirectory(dir.resolve(name));
        }

        private boolean isCompoundGroup(Path p) {
            try {
                Map<String, Object> attrs = readZAttrs(p);
                return COMPOUND_KIND.equals(attrs.get(KIND_ATTR));
            } catch (IOException e) {
                return false;
            }
        }

        private boolean isArray(Path p) {
            return Files.exists(p.resolve(".zarray"));
        }

        @Override
        public StorageGroup openGroup(String name) {
            Path p = dir.resolve(name);
            if (!Files.isDirectory(p) || !Files.exists(p.resolve(".zgroup"))) {
                throw new java.util.NoSuchElementException(
                        "group not found: " + name);
            }
            if (isCompoundGroup(p)) {
                throw new java.util.NoSuchElementException(
                        "'" + name + "' is a compound dataset; use openDataset()");
            }
            return new ZGroup(name, p);
        }

        @Override
        public StorageGroup createGroup(String name) {
            Path p = dir.resolve(name);
            if (Files.exists(p)) {
                throw new IllegalArgumentException("already exists: " + name);
            }
            try {
                Files.createDirectories(p);
                writeZGroup(p);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            return new ZGroup(name, p);
        }

        @Override
        public void deleteChild(String name) {
            Path p = dir.resolve(name);
            try { deleteRecursive(p); } catch (IOException e) {
                throw new RuntimeException(e);
            }
        }

        @Override
        public StorageDataset openDataset(String name) {
            Path p = dir.resolve(name);
            if (!Files.isDirectory(p)) {
                throw new java.util.NoSuchElementException(
                        "dataset not found: " + name);
            }
            if (isCompoundGroup(p)) {
                return new ZCompoundDataset(name, p);
            }
            if (isArray(p)) {
                return new ZPrimitiveDataset(name, p);
            }
            throw new java.util.NoSuchElementException(
                    "'" + name + "' is a group, not a dataset");
        }

        @Override
        public StorageDataset createDataset(String n, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel) {
            if (compression != Compression.NONE && compression != null) {
                throw new UnsupportedOperationException(
                        "ZarrProvider (Java): compression not implemented in v0.8");
            }
            long[] shape = { length };
            long[] chunks = { chunkSize > 0 ? chunkSize : length };
            Path p = dir.resolve(n);
            if (Files.exists(p)) {
                throw new IllegalArgumentException("already exists: " + n);
            }
            try {
                Files.createDirectories(p);
                writeZArray(p, shape, chunks, precision);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            return new ZPrimitiveDataset(n, p);
        }

        @Override
        public StorageDataset createDatasetND(String n, Precision precision,
                                                long[] shape, long[] chunks,
                                                Compression compression,
                                                int compressionLevel) {
            if (compression != Compression.NONE && compression != null) {
                throw new UnsupportedOperationException(
                        "ZarrProvider (Java): compression not implemented in v0.8");
            }
            Path p = dir.resolve(n);
            if (Files.exists(p)) {
                throw new IllegalArgumentException("already exists: " + n);
            }
            long[] chunksResolved;
            if (chunks == null) {
                chunksResolved = shape.clone();
            } else {
                chunksResolved = chunks.clone();
            }
            try {
                Files.createDirectories(p);
                writeZArray(p, shape.clone(), chunksResolved, precision);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            return new ZPrimitiveDataset(n, p);
        }

        @Override
        public StorageDataset createCompoundDataset(String n,
                                                     List<CompoundField> fields,
                                                     long count) {
            Path p = dir.resolve(n);
            if (Files.exists(p)) {
                throw new IllegalArgumentException("already exists: " + n);
            }
            try {
                Files.createDirectories(p);
                writeZGroup(p);
                Map<String, Object> attrs = new LinkedHashMap<>();
                attrs.put(KIND_ATTR, COMPOUND_KIND);
                attrs.put(SCHEMA_ATTR, schemaToJson(fields));
                attrs.put(COUNT_ATTR, count);
                attrs.put(ROWS_ATTR, "[]");
                writeZAttrs(p, attrs);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            return new ZCompoundDataset(n, p);
        }

        // ── Attributes ──

        private Map<String, Object> attrs() {
            try { return readZAttrs(dir); }
            catch (IOException e) { throw new RuntimeException(e); }
        }

        private void saveAttrs(Map<String, Object> m) {
            try { writeZAttrs(dir, m); }
            catch (IOException e) { throw new RuntimeException(e); }
        }

        @Override
        public boolean hasAttribute(String name) {
            if (name.startsWith("_mpgo_")) return false;
            return attrs().containsKey(name);
        }

        @Override
        public Object getAttribute(String name) { return attrs().get(name); }

        @Override
        public void setAttribute(String name, Object value) {
            Map<String, Object> m = attrs();
            m.put(name, coerceForJson(value));
            saveAttrs(m);
        }

        @Override
        public void deleteAttribute(String name) {
            Map<String, Object> m = attrs();
            if (m.remove(name) != null) saveAttrs(m);
        }

        @Override
        public List<String> attributeNames() {
            List<String> out = new ArrayList<>();
            for (String k : attrs().keySet()) {
                if (!k.startsWith("_mpgo_")) out.add(k);
            }
            return out;
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Primitive dataset implementation
    // ────────────────────────────────────────────────────────────────────

    static final class ZPrimitiveDataset implements StorageDataset {
        private final String name;
        private final Path dir;
        private final Precision precision;
        private final long[] shape;
        private final long[] chunks;
        private Object compressor;  // v0.9: null = uncompressed; non-null = zlib metadata dict

        ZPrimitiveDataset(String name, Path dir) {
            this.name = name;
            this.dir = dir;
            try {
                Map<String, Object> meta = readZArray(dir);
                this.precision = precisionFor((String) meta.get("dtype"));
                this.shape = readLongArray(meta.get("shape"));
                this.chunks = readLongArray(meta.get("chunks"));
                Object comp = meta.get("compressor");
                this.compressor = comp;
                if (comp != null) {
                    String codecId = compressorId(comp);
                    if (!"zlib".equals(codecId)) {
                        // v0.9: support Python's default zlib chunks; defer
                        // blosc / lz4 / zstd until a milestone needs them.
                        throw new UnsupportedOperationException(
                                "ZarrProvider (Java): compressor '" + codecId
                                + "' not supported in v0.9 (array " + name
                                + " uses " + comp + ")");
                    }
                }
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
        }

        @Override public String name() { return name; }
        @Override public Precision precision() { return precision; }
        @Override public long[] shape() { return shape.clone(); }
        @Override public long[] chunks() { return chunks.clone(); }
        @Override public List<CompoundField> compoundFields() { return null; }

        private long totalElements() {
            long n = 1;
            for (long d : shape) n *= d;
            return n;
        }

        @Override
        public Object readAll() {
            // Assemble chunks in row-major C order into a flat buffer,
            // then convert to the typed Java array.
            int bpe = bytesPerElement(precision);
            long total = totalElements();
            ByteBuffer buf = ByteBuffer.allocate((int) (total * bpe))
                    .order(ByteOrder.LITTLE_ENDIAN);
            int[] chunkCounts = new int[shape.length];
            for (int i = 0; i < shape.length; i++) {
                chunkCounts[i] = (int) ((shape[i] + chunks[i] - 1) / chunks[i]);
            }
            int[] idx = new int[shape.length];
            writeChunksIntoBuffer(buf, idx, 0, chunkCounts, bpe);
            return bytesToArray(buf.array(), precision);
        }

        private void writeChunksIntoBuffer(ByteBuffer out, int[] idx, int dim,
                                             int[] chunkCounts, int bpe) {
            if (dim == shape.length) {
                Path chunkPath = dir.resolve(chunkFileName(idx));
                byte[] chunkBytes = readChunk(chunkPath, idx, bpe);
                copyChunkIntoBuffer(out, idx, chunkBytes, bpe);
                return;
            }
            for (int i = 0; i < chunkCounts[dim]; i++) {
                idx[dim] = i;
                writeChunksIntoBuffer(out, idx, dim + 1, chunkCounts, bpe);
            }
        }

        private String chunkFileName(int[] idx) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < idx.length; i++) {
                if (i > 0) sb.append(".");
                sb.append(idx[i]);
            }
            return sb.toString();
        }

        private byte[] readChunk(Path chunkPath, int[] idx, int bpe) {
            long chunkSize = 1;
            for (long c : chunks) chunkSize *= c;
            int expected = (int) (chunkSize * bpe);
            if (!Files.exists(chunkPath)) {
                // Missing chunk → fill with fill_value (0 for our precisions).
                return new byte[expected];
            }
            try {
                byte[] raw = Files.readAllBytes(chunkPath);
                // v0.9: decompress if the array carries a compressor spec.
                byte[] plain = decompressChunk(compressor, raw, expected);
                if (plain.length < expected) {
                    byte[] padded = new byte[expected];
                    System.arraycopy(plain, 0, padded, 0, plain.length);
                    return padded;
                }
                return plain;
            } catch (IOException e) {
                throw new RuntimeException("chunk read failed: " + chunkPath, e);
            }
        }

        private void copyChunkIntoBuffer(ByteBuffer out, int[] idx,
                                           byte[] chunkBytes, int bpe) {
            // Logical chunk origin in element coordinates.
            long[] origin = new long[shape.length];
            long[] chunkLogicalSize = new long[shape.length];
            for (int i = 0; i < shape.length; i++) {
                origin[i] = (long) idx[i] * chunks[i];
                long end = Math.min(origin[i] + chunks[i], shape[i]);
                chunkLogicalSize[i] = end - origin[i];
            }
            // Iterate over the logical (clipped) chunk region.
            long[] sub = new long[shape.length];
            iterateChunk(out, sub, 0, chunkLogicalSize, origin, chunkBytes, bpe);
        }

        private void iterateChunk(ByteBuffer out, long[] sub, int dim,
                                    long[] size, long[] origin,
                                    byte[] chunkBytes, int bpe) {
            if (dim == shape.length) {
                // Source offset in the chunk file (using the chunk shape,
                // NOT the clipped logical size).
                long srcIdx = 0;
                long srcStride = 1;
                for (int i = shape.length - 1; i >= 0; i--) {
                    srcIdx += sub[i] * srcStride;
                    srcStride *= chunks[i];
                }
                // Destination offset in the global flat buffer.
                long dstIdx = 0;
                long dstStride = 1;
                for (int i = shape.length - 1; i >= 0; i--) {
                    dstIdx += (origin[i] + sub[i]) * dstStride;
                    dstStride *= shape[i];
                }
                int srcOff = (int) (srcIdx * bpe);
                int dstOff = (int) (dstIdx * bpe);
                out.position(dstOff);
                out.put(chunkBytes, srcOff, bpe);
                return;
            }
            for (long i = 0; i < size[dim]; i++) {
                sub[dim] = i;
                iterateChunk(out, sub, dim + 1, size, origin, chunkBytes, bpe);
            }
        }

        @Override
        public Object readSlice(long offset, long count) {
            Object all = readAll();
            return sliceTypedArray(all, (int) offset, (int) count);
        }

        private static Object sliceTypedArray(Object src, int offset, int count) {
            if (src instanceof double[] a) {
                double[] o = new double[count];
                System.arraycopy(a, offset, o, 0, count); return o;
            }
            if (src instanceof float[] a) {
                float[] o = new float[count];
                System.arraycopy(a, offset, o, 0, count); return o;
            }
            if (src instanceof long[] a) {
                long[] o = new long[count];
                System.arraycopy(a, offset, o, 0, count); return o;
            }
            if (src instanceof int[] a) {
                int[] o = new int[count];
                System.arraycopy(a, offset, o, 0, count); return o;
            }
            throw new IllegalStateException("unsupported element type " + src.getClass());
        }

        @Override
        public void writeAll(Object data) {
            int bpe = bytesPerElement(precision);
            long total = totalElements();
            byte[] flat = arrayToLittleEndianBytes(data, precision, (int) total);

            int[] chunkCounts = new int[shape.length];
            for (int i = 0; i < shape.length; i++) {
                chunkCounts[i] = (int) ((shape[i] + chunks[i] - 1) / chunks[i]);
            }
            int[] idx = new int[shape.length];
            writeChunksFromBuffer(flat, idx, 0, chunkCounts, bpe);
        }

        private void writeChunksFromBuffer(byte[] flat, int[] idx, int dim,
                                             int[] chunkCounts, int bpe) {
            if (dim == shape.length) {
                long chunkElements = 1;
                for (long c : chunks) chunkElements *= c;
                byte[] chunkBytes = new byte[(int) (chunkElements * bpe)];

                long[] origin = new long[shape.length];
                long[] logicalSize = new long[shape.length];
                for (int i = 0; i < shape.length; i++) {
                    origin[i] = (long) idx[i] * chunks[i];
                    long end = Math.min(origin[i] + chunks[i], shape[i]);
                    logicalSize[i] = end - origin[i];
                }

                long[] sub = new long[shape.length];
                fillChunkBytes(flat, sub, 0, logicalSize, origin, chunkBytes, bpe);

                try {
                    Files.write(dir.resolve(chunkFileName(idx)), chunkBytes,
                            StandardOpenOption.CREATE,
                            StandardOpenOption.TRUNCATE_EXISTING);
                } catch (IOException e) {
                    throw new RuntimeException(e);
                }
                return;
            }
            for (int i = 0; i < chunkCounts[dim]; i++) {
                idx[dim] = i;
                writeChunksFromBuffer(flat, idx, dim + 1, chunkCounts, bpe);
            }
        }

        private void fillChunkBytes(byte[] flat, long[] sub, int dim,
                                      long[] size, long[] origin,
                                      byte[] chunkBytes, int bpe) {
            if (dim == shape.length) {
                long srcIdx = 0, srcStride = 1;
                for (int i = shape.length - 1; i >= 0; i--) {
                    srcIdx += (origin[i] + sub[i]) * srcStride;
                    srcStride *= shape[i];
                }
                long dstIdx = 0, dstStride = 1;
                for (int i = shape.length - 1; i >= 0; i--) {
                    dstIdx += sub[i] * dstStride;
                    dstStride *= chunks[i];
                }
                System.arraycopy(flat, (int) (srcIdx * bpe),
                        chunkBytes, (int) (dstIdx * bpe), bpe);
                return;
            }
            for (long i = 0; i < size[dim]; i++) {
                sub[dim] = i;
                fillChunkBytes(flat, sub, dim + 1, size, origin, chunkBytes, bpe);
            }
        }

        // ── Attributes ──

        private Map<String, Object> attrs() {
            try { return readZAttrs(dir); }
            catch (IOException e) { throw new RuntimeException(e); }
        }

        private void saveAttrs(Map<String, Object> m) {
            try { writeZAttrs(dir, m); }
            catch (IOException e) { throw new RuntimeException(e); }
        }

        @Override public boolean hasAttribute(String n) { return attrs().containsKey(n); }
        @Override public Object getAttribute(String n) { return attrs().get(n); }
        @Override public void setAttribute(String n, Object v) {
            Map<String, Object> m = attrs(); m.put(n, coerceForJson(v)); saveAttrs(m);
        }
        @Override public void deleteAttribute(String n) {
            Map<String, Object> m = attrs(); if (m.remove(n) != null) saveAttrs(m);
        }
        @Override public List<String> attributeNames() {
            return new ArrayList<>(attrs().keySet());
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Compound dataset implementation
    // ────────────────────────────────────────────────────────────────────

    static final class ZCompoundDataset implements StorageDataset {
        private final String name;
        private final Path dir;
        private List<CompoundField> fields;
        private long count;

        ZCompoundDataset(String name, Path dir) {
            this.name = name;
            this.dir = dir;
            try {
                Map<String, Object> attrs = readZAttrs(dir);
                this.fields = schemaFromJson((String) attrs.get(SCHEMA_ATTR));
                Object c = attrs.get(COUNT_ATTR);
                this.count = c == null ? 0L : ((Number) c).longValue();
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
        }

        @Override public String name() { return name; }
        @Override public Precision precision() { return null; }
        @Override public long[] shape() { return new long[]{ count }; }
        @Override public List<CompoundField> compoundFields() { return fields; }

        @Override
        public Object readAll() {
            try {
                Map<String, Object> attrs = readZAttrs(dir);
                String blob = (String) attrs.getOrDefault(ROWS_ATTR, "[]");
                Object parsed = MiniJson.parse(blob);
                List<Map<String, Object>> out = new ArrayList<>();
                if (parsed instanceof List<?> list) {
                    for (Object r : list) {
                        if (r instanceof Map<?, ?> m) {
                            Map<String, Object> row = new LinkedHashMap<>();
                            for (CompoundField f : fields) {
                                row.put(f.name(), m.get(f.name()));
                            }
                            out.add(row);
                        }
                    }
                }
                return out;
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
        }

        @Override
        public Object readSlice(long offset, long count) {
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> all = (List<Map<String, Object>>) readAll();
            int from = (int) offset;
            int to = (int) Math.min(all.size(), offset + count);
            return new ArrayList<>(all.subList(from, to));
        }

        @Override
        public void writeAll(Object data) {
            List<Map<String, Object>> rows = new ArrayList<>();
            if (data instanceof List<?> list) {
                for (Object r : list) {
                    if (r instanceof Map<?, ?> m) {
                        Map<String, Object> row = new LinkedHashMap<>();
                        for (CompoundField f : fields) {
                            Object v = m.get(f.name());
                            row.put(f.name(), coerceCompoundField(v, f.kind()));
                        }
                        rows.add(row);
                    } else if (r instanceof Object[] arr) {
                        Map<String, Object> row = new LinkedHashMap<>();
                        for (int i = 0; i < fields.size() && i < arr.length; i++) {
                            row.put(fields.get(i).name(),
                                    coerceCompoundField(arr[i], fields.get(i).kind()));
                        }
                        rows.add(row);
                    }
                }
            }
            try {
                Map<String, Object> attrs = readZAttrs(dir);
                attrs.put(ROWS_ATTR, MiniJson.serialise(rows));
                attrs.put(COUNT_ATTR, (long) rows.size());
                writeZAttrs(dir, attrs);
                this.count = rows.size();
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
        }

        private Map<String, Object> attrs() {
            try { return readZAttrs(dir); }
            catch (IOException e) { throw new RuntimeException(e); }
        }

        private void saveAttrs(Map<String, Object> m) {
            try { writeZAttrs(dir, m); }
            catch (IOException e) { throw new RuntimeException(e); }
        }

        @Override public boolean hasAttribute(String n) {
            return !n.startsWith("_mpgo_") && attrs().containsKey(n);
        }
        @Override public Object getAttribute(String n) { return attrs().get(n); }
        @Override public void setAttribute(String n, Object v) {
            Map<String, Object> m = attrs(); m.put(n, coerceForJson(v)); saveAttrs(m);
        }
        @Override public void deleteAttribute(String n) {
            Map<String, Object> m = attrs(); if (m.remove(n) != null) saveAttrs(m);
        }
        @Override public List<String> attributeNames() {
            List<String> out = new ArrayList<>();
            for (String k : attrs().keySet()) {
                if (!k.startsWith("_mpgo_")) out.add(k);
            }
            return out;
        }
    }

    // ── Compound schema helpers ─────────────────────────────────────────

    static String schemaToJson(List<CompoundField> fields) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < fields.size(); i++) {
            if (i > 0) sb.append(",");
            CompoundField f = fields.get(i);
            sb.append("{\"name\":\"").append(jsonEscape(f.name())).append("\",");
            sb.append("\"kind\":\"").append(kindToString(f.kind())).append("\"}");
        }
        sb.append("]");
        return sb.toString();
    }

    static List<CompoundField> schemaFromJson(String blob) {
        List<CompoundField> out = new ArrayList<>();
        Object parsed = MiniJson.parse(blob);
        if (parsed instanceof List<?> list) {
            for (Object entry : list) {
                if (entry instanceof Map<?, ?> m) {
                    String name = (String) m.get("name");
                    String kind = (String) m.get("kind");
                    out.add(new CompoundField(name, kindFromString(kind)));
                }
            }
        }
        return out;
    }

    static String kindToString(CompoundField.Kind k) {
        return switch (k) {
            case UINT32 -> "uint32";
            case INT64 -> "int64";
            case FLOAT64 -> "float64";
            case VL_STRING -> "vl_string";
        };
    }

    static CompoundField.Kind kindFromString(String s) {
        return switch (s) {
            case "uint32" -> CompoundField.Kind.UINT32;
            case "int64"  -> CompoundField.Kind.INT64;
            case "float64" -> CompoundField.Kind.FLOAT64;
            case "vl_string" -> CompoundField.Kind.VL_STRING;
            default -> throw new IllegalArgumentException("unknown kind: " + s);
        };
    }

    static Object coerceCompoundField(Object v, CompoundField.Kind kind) {
        return switch (kind) {
            case VL_STRING -> v == null ? "" :
                    (v instanceof byte[] b ? new String(b, StandardCharsets.UTF_8)
                            : v.toString());
            case FLOAT64 -> v == null ? 0.0 : ((Number) v).doubleValue();
            case INT64, UINT32 -> v == null ? 0L : ((Number) v).longValue();
        };
    }

    // ── Attribute coercion (zarr attrs go through JSON) ────────────────

    static Object coerceForJson(Object v) {
        if (v == null) return null;
        if (v instanceof Boolean || v instanceof String
                || v instanceof Number) return v;
        if (v instanceof byte[] b) return new String(b, StandardCharsets.UTF_8);
        if (v instanceof long[] a) {
            List<Object> out = new ArrayList<>(a.length);
            for (long x : a) out.add(x);
            return out;
        }
        if (v instanceof int[] a) {
            List<Object> out = new ArrayList<>(a.length);
            for (int x : a) out.add((long) x);
            return out;
        }
        if (v instanceof double[] a) {
            List<Object> out = new ArrayList<>(a.length);
            for (double x : a) out.add(x);
            return out;
        }
        if (v instanceof List<?> l) {
            List<Object> out = new ArrayList<>(l.size());
            for (Object x : l) out.add(coerceForJson(x));
            return out;
        }
        return v.toString();
    }

    // ── Flat-byte ↔ typed array conversions ────────────────────────────

    static Object bytesToArray(byte[] raw, Precision p) {
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        return switch (p) {
            case FLOAT64 -> {
                int n = raw.length / 8;
                double[] out = new double[n];
                for (int i = 0; i < n; i++) out[i] = bb.getDouble();
                yield out;
            }
            case FLOAT32 -> {
                int n = raw.length / 4;
                float[] out = new float[n];
                for (int i = 0; i < n; i++) out[i] = bb.getFloat();
                yield out;
            }
            case INT64 -> {
                int n = raw.length / 8;
                long[] out = new long[n];
                for (int i = 0; i < n; i++) out[i] = bb.getLong();
                yield out;
            }
            case INT32, UINT32 -> {
                int n = raw.length / 4;
                int[] out = new int[n];
                for (int i = 0; i < n; i++) out[i] = bb.getInt();
                yield out;
            }
            case COMPLEX128 -> raw;
        };
    }

    static byte[] arrayToLittleEndianBytes(Object data, Precision p, int totalElems) {
        ByteBuffer bb = ByteBuffer.allocate(totalElems * bytesPerElement(p))
                .order(ByteOrder.LITTLE_ENDIAN);
        switch (p) {
            case FLOAT64 -> {
                double[] a = (double[]) data;
                for (int i = 0; i < totalElems; i++) bb.putDouble(a[i]);
            }
            case FLOAT32 -> {
                float[] a = (float[]) data;
                for (int i = 0; i < totalElems; i++) bb.putFloat(a[i]);
            }
            case INT64 -> {
                long[] a = (long[]) data;
                for (int i = 0; i < totalElems; i++) bb.putLong(a[i]);
            }
            case INT32, UINT32 -> {
                int[] a = (int[]) data;
                for (int i = 0; i < totalElems; i++) bb.putInt(a[i]);
            }
            default -> throw new UnsupportedOperationException(
                    "unsupported precision " + p);
        }
        return bb.array();
    }

    // ── JSON string escaping ────────────────────────────────────────────

    static String jsonEscape(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"'  -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        return sb.toString();
    }

    // Enumerate all attribute keys that the Python/ObjC providers reserve
    // (prefix "_mpgo_"). Callers don't normally see these but the reserved
    // set is documented for the v1.0 API freeze.
    static final Set<String> RESERVED_ATTR_PREFIXES = new LinkedHashSet<>(List.of(
        "_mpgo_"
    ));
}
