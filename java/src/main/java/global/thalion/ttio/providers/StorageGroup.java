/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;

import java.util.List;

/**
 * Named directory of subgroups, datasets, and attributes.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOStorageGroup}, Python
 * {@code ttio.providers.base.StorageGroup}.</p>
 *
 *
 */
public interface StorageGroup extends AutoCloseable {

    /** @return the short (last-path-segment) name of this group;
     *  {@code "/"} for the root group. */
    String name();

    // ── Children ─────────────────────────────────────────────────

    /** @return every child link name (sub-group or dataset) directly
     *  under this group in storage order. */
    List<String> childNames();

    /** @param name  the child link name
     *  @return {@code true} when a sub-group or dataset of that name
     *  exists directly under this group. */
    boolean hasChild(String name);

    /** Open an existing sub-group.
     *
     *  @param name  the sub-group name
     *  @return the opened {@link StorageGroup}
     */
    StorageGroup openGroup(String name);

    /** Create a new sub-group.
     *
     *  @param name  the sub-group name (must not collide with an
     *               existing child)
     *  @return the newly-created {@link StorageGroup}
     */
    StorageGroup createGroup(String name);

    /** Delete a child link (sub-group or dataset). No-op when absent.
     *
     *  @param name  the child name
     */
    void deleteChild(String name);

    // ── Datasets ─────────────────────────────────────────────────

    /** Open an existing dataset directly under this group.
     *
     *  @param name  the dataset name
     *  @return the opened {@link StorageDataset}
     */
    StorageDataset openDataset(String name);

    /** Create a primitive 1-D dataset.
     *
     *  @param name              the dataset name
     *  @param precision         the element type
     *  @param length            element count along the single axis
     *  @param chunkSize         chunk extent (honoured only when the
     *                           backend reports
     *                           {@link StorageProvider#supportsChunking})
     *  @param compression       compression algorithm
     *  @param compressionLevel  algorithm-specific level (0 = none)
     *  @return the newly-created {@link StorageDataset}
     */
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

    /** Create a 1-D compound dataset.
     *
     *  @param name    the dataset name
     *  @param fields  the ordered list of fields in one record
     *  @param count   number of records
     *  @return the newly-created {@link StorageDataset}
     */
    StorageDataset createCompoundDataset(String name,
                                          List<CompoundField> fields,
                                          long count);

    // ── Attributes ───────────────────────────────────────────────

    /** @param name  the attribute name
     *  @return {@code true} when the attribute is present on this group. */
    boolean hasAttribute(String name);

    /** Read an attribute value.
     *
     *  @param name  the attribute name
     *  @return the stored value boxed into a Java object (string, boxed
     *          numeric, or primitive array), or {@code null} if absent
     */
    Object getAttribute(String name);

    /** Write an attribute. Replaces any existing entry of the same name.
     *
     *  @param name   the attribute name
     *  @param value  the value to store (string, boxed numeric, or
     *                primitive array)
     */
    void setAttribute(String name, Object value);

    /** Remove an attribute. No-op when the attribute is absent.
     *
     *  @param name  the attribute name
     */
    void deleteAttribute(String name);

    /** @return every attribute name on this group. */
    List<String> attributeNames();

    // ── Lifecycle ────────────────────────────────────────────────

    /** Release per-group native handles. Default no-op. */
    @Override
    default void close() {}
}
