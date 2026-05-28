/* TTI-O Java Implementation / Copyright (c) 2026 The Thalion Initiative / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio;

import global.thalion.ttio.Enums.Polarity;

import java.util.ArrayList;
import java.util.List;

/**
 * Compressed-domain query over a {@link SpectrumIndex}. Predicates
 * combine with AND (intersection).
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C {@code TTIOQuery},
 * Python {@code ttio.query.Query}.</p>
 *
 *
 */
public final class Query {

    private final SpectrumIndex index;
    private ValueRange rtRange;
    private Integer msLevel;
    private Polarity polarity;
    private ValueRange precursorMzRange;
    private Double basePeakThreshold;

    private Query(SpectrumIndex index) {
        this.index = index;
    }

    /**
     * Start a new query against a spectrum index.
     *
     * @param index the index to query
     * @return      a fresh {@code Query} with no predicates set
     */
    public static Query onIndex(SpectrumIndex index) {
        return new Query(index);
    }

    /**
     * Restrict matches to spectra whose retention time lies inside
     * {@code range} (inclusive).
     *
     * @param range retention-time range in seconds
     * @return      {@code this} for fluent chaining
     */
    public Query withRetentionTimeRange(ValueRange range) {
        this.rtRange = range;
        return this;
    }

    /**
     * Restrict matches to spectra with the given MS level.
     *
     * @param level MS level (1, 2, 3, ...)
     * @return      {@code this} for fluent chaining
     */
    public Query withMsLevel(int level) {
        this.msLevel = level;
        return this;
    }

    /**
     * Restrict matches to spectra with the given polarity.
     *
     * @param polarity polarity enum value
     * @return         {@code this} for fluent chaining
     */
    public Query withPolarity(Polarity polarity) {
        this.polarity = polarity;
        return this;
    }

    /**
     * Restrict matches to spectra whose precursor m/z lies inside
     * {@code range} (inclusive).
     *
     * @param range precursor m/z range
     * @return      {@code this} for fluent chaining
     */
    public Query withPrecursorMzRange(ValueRange range) {
        this.precursorMzRange = range;
        return this;
    }

    /**
     * Restrict matches to spectra whose base-peak intensity is at
     * least {@code threshold}.
     *
     * @param threshold inclusive lower bound on base-peak intensity
     * @return          {@code this} for fluent chaining
     */
    public Query withBasePeakIntensityAtLeast(double threshold) {
        this.basePeakThreshold = threshold;
        return this;
    }

    /** @return indices matching all predicates. */
    public List<Integer> matchingIndices() {
        List<Integer> out = new ArrayList<>();
        for (int i = 0; i < index.count(); i++) {
            if (rtRange != null) {
                double t = index.retentionTimeAt(i);
                if (t < rtRange.minimum() || t > rtRange.maximum()) continue;
            }
            if (msLevel != null && index.msLevelAt(i) != msLevel) continue;
            if (polarity != null && index.polarityAt(i) != polarity) continue;
            if (precursorMzRange != null) {
                double m = index.precursorMzAt(i);
                if (m < precursorMzRange.minimum() || m > precursorMzRange.maximum()) continue;
            }
            if (basePeakThreshold != null
                && index.basePeakIntensityAt(i) < basePeakThreshold) continue;
            out.add(i);
        }
        return out;
    }
}
