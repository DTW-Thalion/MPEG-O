/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import global.thalion.ttio.Enums.Precision;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * One 1-D typed array or compound-record array.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOStorageDataset}, Python
 * {@code ttio.providers.base.StorageDataset}.</p>
 *
 *
 */
public interface StorageDataset extends AutoCloseable {

    /** @return the short (last-path-segment) name of this dataset. */
    String name();

    /** Primitive precision, or {@code null} for compound datasets
     *  (use {@link #compoundFields()} there). */
    Precision precision();

    /** Full shape tuple. 1-D datasets return {@code {N}}. */
    long[] shape();

    /** Size along the first axis (= {@code shape()[0]}). */
    default long length() {
        long[] s = shape();
        return s != null && s.length > 0 ? s[0] : 0L;
    }

    /** Chunk shape, or {@code null} for contiguous storage. */
    default long[] chunks() { return null; }

    /** Compound field schema, or {@code null} for primitive datasets. */
    List<CompoundField> compoundFields();

    // ── Read / write ─────────────────────────────────────────────

    /** Read all elements.
     *
     *  <p>Return type varies by backend :</p>
     *  <ul>
     *    <li>Primitive datasets: native Java array matching
     *        {@link #precision()} — {@code double[]} for FLOAT64,
     *        {@code int[]} for INT32/UINT32, {@code long[]} for INT64,
     *        {@code float[]} for FLOAT32, {@code byte[]} (native
     *        packing) for COMPLEX128.</li>
     *    <li>Compound datasets — HDF5: {@code List<Object[]>} of row
     *        values in field-order.</li>
     *    <li>Compound datasets — SQLite / non-typed backends:
     *        {@code List<Map<String, Object>>} keyed by field name.</li>
     *  </ul>
     *
     *  <p>For backend-agnostic row iteration call {@link #readRows()} —
     *  it normalises both compound shapes into a uniform list of
     *  field-keyed maps.</p>
     */
    Object readAll();

    /** Hyperslab read: {@code count} elements starting at
     *  {@code offset}. Same return-type rules as {@link #readAll()}. */
    Object readSlice(long offset, long count);

    /** @return {@code true} when the dataset was created extendable and
     *  accepts {@link #append}. */
    default boolean extendable() { return false; }

    /** Grow the dataset along its first axis by the elements (or compound
     *  rows, as {@code List<Object[]>} in field order) of {@code data}.
     *
     *  @throws UnsupportedOperationException when the dataset is not
     *          extendable */
    default void append(Object data) {
        throw new UnsupportedOperationException(
            "dataset '" + name() + "' is not extendable");
    }

    /** Overwrite {@code data.length} elements in place starting at
     *  {@code offset}; the dataset does not grow. */
    default void writeSlice(long offset, Object data) {
        throw new UnsupportedOperationException(
            getClass().getSimpleName() + " does not implement writeSlice");
    }

    /** Write all elements.
     *
     *  @param data  primitive array matching {@link #precision} for
     *               primitive datasets, or a list of records for
     *               compound datasets (shape matches the value returned
     *               by {@link #readAll})
     */
    void writeAll(Object data);

    /** Read a compound dataset as a uniform
     *  {@code List<Map<String, Object>>} regardless of backend. Default
     *  implementation converts the HDF5 {@code List<Object[]>} shape;
     *  SQLite and other map-backed providers pass through.
     *
     *  <p>Backend-agnostic compound access — callers do not need to
     *  branch on provider type.</p>
     *
     *  @return one map per record, keyed by field name
     *  @throws IllegalStateException  when called on a primitive dataset
     */
    @SuppressWarnings("unchecked")
    default List<Map<String, Object>> readRows() {
        List<CompoundField> fields = compoundFields();
        if (fields == null) {
            throw new IllegalStateException(
                "readRows() is only valid for compound datasets; '"
                + name() + "' is primitive");
        }
        Object raw = readAll();
        if (raw instanceof List<?> list && !list.isEmpty()
                && list.get(0) instanceof Map<?, ?>) {
            return (List<Map<String, Object>>) raw;
        }
        if (raw instanceof List<?> list && !list.isEmpty()
                && list.get(0) instanceof Object[]) {
            List<Object[]> rows = (List<Object[]>) raw;
            List<Map<String, Object>> out = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                Map<String, Object> m = new LinkedHashMap<>(fields.size());
                for (int i = 0; i < fields.size() && i < row.length; i++) {
                    m.put(fields.get(i).name(), row[i]);
                }
                out.add(m);
            }
            return out;
        }
        if (raw instanceof List<?> list && list.isEmpty()) {
            return List.of();
        }
        throw new IllegalStateException(
            "unexpected compound readAll() return type "
            + (raw == null ? "null" : raw.getClass().getName())
            + " for dataset '" + name() + "'");
    }

    /** Return the dataset contents as a byte stream in the TTIO
     *  canonical layout ().
     *
     *  <p>Semantics:</p>
     *  <ul>
     *    <li>Primitive numeric: little-endian packed values.</li>
     *    <li>Compound: rows in storage order; fields in declaration
     *        order. VL strings as {@code u32_le(length) || utf-8_bytes}.
     *        Numeric fields little-endian.</li>
     *  </ul>
     *
     *  <p>Signatures and encryption consume this so a signed or
     *  encrypted dataset verifies identically regardless of which
     *  provider wrote it. Default implementation handles
     *  {@code Hdf5DatasetAdapter}'s native arrays and
     *  {@code SqliteDataset}'s list-of-maps; providers with a
     *  zero-copy fast path may override. */
    default byte[] readCanonicalBytes() {
        Object raw = readAll();
        List<CompoundField> fields = compoundFields();
        if (fields == null) {
            return canonicalisePrimitive(raw, precision());
        }
        // Compound dispatch — rows may be List<Object[]> (HDF5) or
        // List<Map<String,Object>> (SQLite, Memory). Normalise via
        // readRows() and walk.
        return canonicaliseCompoundRows(readRows(), fields);
    }

    /** Helper exposed for providers that want to override
     *  {@link #readCanonicalBytes()} but share the compound path.
     *
     *  @param rows    the records to serialise
     *  @param fields  the field schema (drives encoding order and type)
     *  @return the canonical byte serialisation
     */
    static byte[] canonicaliseCompoundRows(List<Map<String, Object>> rows,
                                            List<CompoundField> fields) {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        try {
            for (Map<String, Object> row : rows) {
                for (CompoundField f : fields) {
                    Object v = row.get(f.name());
                    writeCanonicalField(out, v, f.kind());
                }
            }
        } catch (java.io.IOException e) {
            throw new RuntimeException("canonical compound emit failed", e);
        }
        return out.toByteArray();
    }

    private static void writeCanonicalField(java.io.ByteArrayOutputStream out,
                                             Object value,
                                             CompoundField.Kind kind)
            throws java.io.IOException {
        switch (kind) {
            case VL_BYTES -> {
                byte[] bytes = value == null ? new byte[0] : (byte[]) value;
                ByteBuffer lb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
                lb.putInt(bytes.length);
                out.write(lb.array());
                if (bytes.length > 0) out.write(bytes);
            }
            case VL_STRING -> {
                byte[] bytes;
                if (value == null) {
                    bytes = new byte[0];
                } else if (value instanceof byte[] b) {
                    bytes = b;
                } else {
                    bytes = value.toString().getBytes(StandardCharsets.UTF_8);
                }
                ByteBuffer lb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
                lb.putInt(bytes.length);
                out.write(lb.array());
                if (bytes.length > 0) out.write(bytes);
            }
            case FLOAT64 -> {
                double d = ((Number) value).doubleValue();
                ByteBuffer lb = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
                lb.putDouble(d);
                out.write(lb.array());
            }
            case UINT32 -> {
                int i = ((Number) value).intValue();
                ByteBuffer lb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
                lb.putInt(i);
                out.write(lb.array());
            }
            case INT64, UINT64 -> {
                long l = ((Number) value).longValue();
                ByteBuffer lb = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
                lb.putLong(l);
                out.write(lb.array());
            }
        }
    }

    /** Helper for the primitive canonical path.
     *
     *  @param raw  the array returned by {@link #readAll()}
     *  @param p    the precision of {@code raw}
     *  @return the canonical little-endian byte serialisation
     */
    static byte[] canonicalisePrimitive(Object raw, Precision p) {
        if (p == null) {
            throw new IllegalStateException(
                "canonicalisePrimitive called with null precision");
        }
        return switch (p) {
            case FLOAT64 -> {
                double[] a = (double[]) raw;
                ByteBuffer bb = ByteBuffer.allocate(a.length * 8)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (double d : a) bb.putDouble(d);
                yield bb.array();
            }
            case FLOAT32 -> {
                float[] a = (float[]) raw;
                ByteBuffer bb = ByteBuffer.allocate(a.length * 4)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (float d : a) bb.putFloat(d);
                yield bb.array();
            }
            case INT32, UINT32 -> {
                int[] a = (int[]) raw;
                ByteBuffer bb = ByteBuffer.allocate(a.length * 4)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (int i : a) bb.putInt(i);
                yield bb.array();
            }
            case INT64 -> {
                long[] a = (long[]) raw;
                ByteBuffer bb = ByteBuffer.allocate(a.length * 8)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (long l : a) bb.putLong(l);
                yield bb.array();
            }
            case COMPLEX128 -> {
                // Compound-typed in HDF5, but stored as byte[] in Java
                // (native packing). Caller is responsible for
                // little-endian packing upstream.
                yield (byte[]) raw;
            }
            case UINT8 -> {
                // bytes are endian-neutral; copy through.
                yield (byte[]) raw;
            }
            case UINT16 -> {
                // genomic_index/chromosome_ids: pack short[] as
                // little-endian uint16.
                short[] a = (short[]) raw;
                ByteBuffer bb = ByteBuffer.allocate(a.length * 2)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (short s : a) bb.putShort(s);
                yield bb.array();
            }
            case _RESERVED_INT8 ->
                throw new UnsupportedOperationException(
                    "Precision " + p + " is reserved for cross-language parity");
            case UINT64 -> {
                // genomic index offsets, packed identically
                // to INT64 (twos-complement is the same on the wire).
                long[] a = (long[]) raw;
                ByteBuffer bb = ByteBuffer.allocate(a.length * 8)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (long l : a) bb.putLong(l);
                yield bb.array();
            }
        };
    }

    // ── Attributes ───────────────────────────────────────────────

    /** @param name  the attribute name
     *  @return {@code true} when the attribute is present on this dataset. */
    boolean hasAttribute(String name);

    /** Read an attribute value.
     *
     *  @param name  the attribute name
     *  @return the stored value boxed into a Java object, or {@code null}
     *          if absent
     */
    Object getAttribute(String name);

    /** Write an attribute. Replaces any existing entry of the same name.
     *
     *  @param name   the attribute name
     *  @param value  the value to store (string, boxed numeric, or
     *                primitive array)
     */
    void setAttribute(String name, Object value);

    /** Remove an attribute. No-op if the attribute does not exist.
     *  Mirrors the Python ABC and ObjC
     *  {@code -deleteAttributeNamed:error:} surfaces.
     *
     *  @param name  the attribute name
     */
    void deleteAttribute(String name);

    /** List attribute names. Returns an empty list if there are no
     *  attributes. */
    List<String> attributeNames();

    // ── Lifecycle ────────────────────────────────────────────────

    /** Release per-dataset native handles. Default no-op for backends
     *  that share lifetime with the owning provider. */
    @Override
    default void close() {}
}
