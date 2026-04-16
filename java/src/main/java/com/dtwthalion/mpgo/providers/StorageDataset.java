/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.providers;

import com.dtwthalion.mpgo.Enums.Precision;

import java.util.List;

/** One 1-D typed array or compound-record array. */
public interface StorageDataset extends AutoCloseable {

    String name();

    /** Primitive precision, or {@code null} for compound datasets
     *  (use {@link #compoundFields()} there). */
    Precision precision();

    long length();

    /** Compound field schema, or {@code null} for primitive datasets. */
    List<CompoundField> compoundFields();

    // ── Read / write ─────────────────────────────────────────────

    /** Read all elements. Return type matches the precision:
     *  {@code double[]} for FLOAT64, {@code int[]} for INT32/UINT32,
     *  {@code long[]} for INT64, {@code float[]} for FLOAT32,
     *  {@code byte[]} (native packing) for COMPLEX128. Compound
     *  datasets return a {@code List<Object[]>} of row values. */
    Object readAll();

    /** Hyperslab read: {@code count} elements starting at
     *  {@code offset}. Same return-type rules as {@link #readAll()}. */
    Object readSlice(long offset, long count);

    void writeAll(Object data);

    // ── Attributes ───────────────────────────────────────────────

    boolean hasAttribute(String name);

    Object getAttribute(String name);

    void setAttribute(String name, Object value);

    // ── Lifecycle ────────────────────────────────────────────────

    @Override
    default void close() {}
}
