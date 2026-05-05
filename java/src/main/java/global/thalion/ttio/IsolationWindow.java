/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

/**
 * Precursor isolation window for MS/MS scans, expressed as a target
 * m/z with asymmetric lower/upper offsets in Th (Da).
 *
 * <p>The instrument-reported window spans
 * {@code [targetMz - lowerOffset, targetMz + upperOffset]}. Offsets are
 * non-negative by convention; the lower and upper may differ when the
 * quadrupole is offset from the monoisotopic m/z (common in DIA).</p>
 *
 * <p><b>API status:</b> Stable (v1.1, M74).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOIsolationWindow}, Python
 * {@code ttio.isolation_window.IsolationWindow}.</p>
 *
 *
 */
public record IsolationWindow(double targetMz, double lowerOffset,
                              double upperOffset) {

    /** @return lower m/z bound {@code targetMz - lowerOffset}. */
    public double lowerBound() {
        return targetMz - lowerOffset;
    }

    /** @return upper m/z bound {@code targetMz + upperOffset}. */
    public double upperBound() {
        return targetMz + upperOffset;
    }

    /** @return total isolation width {@code lowerOffset + upperOffset}. */
    public double width() {
        return lowerOffset + upperOffset;
    }
}
