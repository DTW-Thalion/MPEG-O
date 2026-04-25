/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.protocols;

import java.util.List;

/**
 * Objects implementing {@code Indexable} support O(1) random access
 * by integer index and, optionally, by key or range. This is the
 * primary access protocol for collections of spectra, runs, and
 * access units.
 *
 * <p>Key-based and range-based access are declared as default
 * methods that throw {@link UnsupportedOperationException};
 * conformers override them if supported.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOIndexable}, Python
 * {@code ttio.protocols.Indexable}.</p>
 *
 * @param <T> element type
 * @since 0.6
 */
public interface Indexable<T> {

    /** @return the element at {@code index} (0-based). */
    T objectAtIndex(int index);

    /** @return the total number of elements. */
    int count();

    /** Optional. Override to support key-based access. */
    default T objectForKey(Object key) {
        throw new UnsupportedOperationException("objectForKey not supported");
    }

    /** Optional. Override to support range-based access. */
    default List<T> objectsInRange(int start, int stop) {
        throw new UnsupportedOperationException("objectsInRange not supported");
    }
}
