/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.Polarity;

import java.util.ArrayList;
import java.util.List;

/**
 * Compressed-domain query over a {@link SpectrumIndex}. Predicates
 * combine with AND (intersection).
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C {@code MPGOQuery},
 * Python {@code mpeg_o.query.Query}.</p>
 *
 * @since 0.6
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

    public static Query onIndex(SpectrumIndex index) {
        return new Query(index);
    }

    public Query withRetentionTimeRange(ValueRange range) {
        this.rtRange = range;
        return this;
    }

    public Query withMsLevel(int level) {
        this.msLevel = level;
        return this;
    }

    public Query withPolarity(Polarity polarity) {
        this.polarity = polarity;
        return this;
    }

    public Query withPrecursorMzRange(ValueRange range) {
        this.precursorMzRange = range;
        return this;
    }

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
