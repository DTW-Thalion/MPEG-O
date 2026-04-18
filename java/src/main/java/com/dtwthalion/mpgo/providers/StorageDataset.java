/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

import com.dtwthalion.mpgo.Enums.Precision;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * One 1-D typed array or compound-record array.
 *
 * <p><b>API status:</b> Stable (Provisional per M39 — may change
 * before v1.0).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOStorageDataset}, Python
 * {@code mpeg_o.providers.base.StorageDataset}.</p>
 *
 * @since 0.6
 */
public interface StorageDataset extends AutoCloseable {

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
     *  <p>Return type varies by backend (Appendix B Gap 2):</p>
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

    void writeAll(Object data);

    /** Read a compound dataset as a uniform
     *  {@code List<Map<String, Object>>} regardless of backend. Default
     *  implementation converts the HDF5 {@code List<Object[]>} shape;
     *  SQLite and other map-backed providers pass through.
     *
     *  <p>Throws {@link IllegalStateException} if called on a primitive
     *  dataset.</p>
     *
     *  <p>Appendix B Gap 2 — backend-agnostic compound access.</p> */
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

    // ── Attributes ───────────────────────────────────────────────

    boolean hasAttribute(String name);

    Object getAttribute(String name);

    void setAttribute(String name, Object value);

    /** Remove an attribute. No-op if the attribute does not exist.
     *  Appendix B Gap 8 — added for parity with Python ABC and ObjC
     *  {@code -deleteAttributeNamed:error:}. */
    void deleteAttribute(String name);

    /** List attribute names. Returns an empty list if there are no
     *  attributes. Appendix B Gap 8. */
    List<String> attributeNames();

    // ── Lifecycle ────────────────────────────────────────────────

    @Override
    default void close() {}
}
