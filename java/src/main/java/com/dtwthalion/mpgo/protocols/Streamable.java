/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.protocols;

/**
 * Objects implementing {@code Streamable} support sequential access
 * with explicit positioning. This enables efficient iteration over
 * large datasets without materializing the entire collection in
 * memory.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOStreamable}, Python
 * {@code mpeg_o.protocols.Streamable}.</p>
 *
 * @param <T> element type
 * @since 0.6
 */
public interface Streamable<T> {

    /** @return the next element and advance the cursor. */
    T nextObject();

    /** @return {@code true} if {@link #nextObject} may be called. */
    boolean hasMore();

    /** @return 0-based position of the next element to be yielded. */
    int currentPosition();

    /**
     * Reposition the cursor.
     * @return {@code true} on success, {@code false} if out of range.
     */
    boolean seekToPosition(int position);

    /** Reposition the cursor to 0. */
    void reset();
}
