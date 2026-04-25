/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

/**
 * Closed numeric range {@code [minimum, maximum]}. Immutable value
 * class.
 *
 * <p>Used by {@link AxisDescriptor} to describe the bounds of a
 * signal axis.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOValueRange}, Python
 * {@code ttio.value_range.ValueRange}.</p>
 *
 * @since 0.6
 */
public record ValueRange(double minimum, double maximum) {

    /** @return difference between {@code maximum} and {@code minimum}. */
    public double span() {
        return maximum - minimum;
    }

    /** @return {@code true} if {@code value} lies within the closed range. */
    public boolean contains(double value) {
        return minimum <= value && value <= maximum;
    }
}
