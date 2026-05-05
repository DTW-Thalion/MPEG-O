/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;

import java.util.List;

/**
 * Named directory of subgroups, datasets, and attributes.
 *
 * <p><b>API status:</b> Stable (Provisional per M39 — may change
 * before v1.0).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOStorageGroup}, Python
 * {@code ttio.providers.base.StorageGroup}.</p>
 *
 *
 */
public interface StorageGroup extends AutoCloseable {

    String name();

    // ── Children ─────────────────────────────────────────────────

    List<String> childNames();

    boolean hasChild(String name);

    StorageGroup openGroup(String name);

    StorageGroup createGroup(String name);

    void deleteChild(String name);

    // ── Datasets ─────────────────────────────────────────────────

    StorageDataset openDataset(String name);

    /** Create a primitive 1-D dataset. */
    StorageDataset createDataset(String name, Precision precision,
                                  long length, int chunkSize,
                                  Compression compression,
                                  int compressionLevel);

    /** Create a multi-dimensional dataset. 1-D delegates to
     *  {@link #createDataset}; higher ranks require provider override. */
    default StorageDataset createDatasetND(String name, Precision precision,
                                             long[] shape, long[] chunks,
                                             Compression compression,
                                             int compressionLevel) {
        if (shape != null && shape.length == 1) {
            int chunkSize = (chunks != null && chunks.length == 1) ? (int) chunks[0] : 0;
            return createDataset(name, precision, shape[0], chunkSize,
                                  compression, compressionLevel);
        }
        throw new UnsupportedOperationException(
                getClass().getSimpleName() + " does not implement N-D datasets");
    }

    /** Create a 1-D compound dataset. */
    StorageDataset createCompoundDataset(String name,
                                          List<CompoundField> fields,
                                          long count);

    // ── Attributes ───────────────────────────────────────────────

    boolean hasAttribute(String name);

    Object getAttribute(String name);

    void setAttribute(String name, Object value);

    void deleteAttribute(String name);

    List<String> attributeNames();

    // ── Lifecycle ────────────────────────────────────────────────

    /** Release per-group native handles. Default no-op. */
    @Override
    default void close() {}
}
