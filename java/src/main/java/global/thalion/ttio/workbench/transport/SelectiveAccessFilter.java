/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Typed builder for the selective-access filter map passed to
 * {@link WorkbenchTransportClient#download(String, java.util.Map,
 * WorkbenchHandshake.OutputMode, int)}.
 *
 * <p>The underlying handshake already validates filter keys against
 * {@link WorkbenchHandshake#ALLOWED_DOWNLOAD_FILTER_KEYS} -- this
 * builder narrows the API to typed setters so the GUI's filter
 * form (W5.3) cannot accidentally produce a key the server will
 * reject.</p>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.transport.selective_access.SelectiveAccessFilter}.</p>
 */
public final class SelectiveAccessFilter {

    /** Polarity values the daemon recognises. */
    public static final Set<String> ALLOWED_POLARITIES =
        Set.of("positive", "negative");

    private final Map<String, Object> filters = new LinkedHashMap<>();

    public SelectiveAccessFilter msLevel(int level) {
        if (level < 1) {
            throw new IllegalArgumentException(
                "ms_level must be >= 1; got " + level);
        }
        filters.put("ms_level", level);
        return this;
    }

    public SelectiveAccessFilter polarity(String value) {
        if (value == null) {
            filters.remove("polarity");
            return this;
        }
        if (!ALLOWED_POLARITIES.contains(value)) {
            throw new IllegalArgumentException(
                "polarity must be one of " + ALLOWED_POLARITIES
                + "; got '" + value + "'");
        }
        filters.put("polarity", value);
        return this;
    }

    public SelectiveAccessFilter retentionTimeMin(double seconds) {
        if (seconds < 0) {
            throw new IllegalArgumentException(
                "retention_time_min must be >= 0; got " + seconds);
        }
        filters.put("retention_time_min", seconds);
        return this;
    }

    public SelectiveAccessFilter retentionTimeMax(double seconds) {
        if (seconds < 0) {
            throw new IllegalArgumentException(
                "retention_time_max must be >= 0; got " + seconds);
        }
        filters.put("retention_time_max", seconds);
        return this;
    }

    public SelectiveAccessFilter precursorMzMin(double mz) {
        if (mz < 0) {
            throw new IllegalArgumentException(
                "precursor_mz_min must be >= 0; got " + mz);
        }
        filters.put("precursor_mz_min", mz);
        return this;
    }

    public SelectiveAccessFilter precursorMzMax(double mz) {
        if (mz < 0) {
            throw new IllegalArgumentException(
                "precursor_mz_max must be >= 0; got " + mz);
        }
        filters.put("precursor_mz_max", mz);
        return this;
    }

    public SelectiveAccessFilter precursorCharge(int charge) {
        filters.put("precursor_charge", charge);
        return this;
    }

    public SelectiveAccessFilter maxAu(int n) {
        if (n < 1) {
            throw new IllegalArgumentException(
                "max_au must be >= 1; got " + n);
        }
        filters.put("max_au", n);
        return this;
    }

    /** Validate cross-key constraints (rt_max >= rt_min, mz_max >= mz_min)
     *  and throw {@link IllegalStateException} if violated. Per-key range
     *  checks are already enforced by the typed setters. */
    public SelectiveAccessFilter validate() {
        validateRange("retention_time_min", "retention_time_max");
        validateRange("precursor_mz_min", "precursor_mz_max");
        return this;
    }

    private void validateRange(String minKey, String maxKey) {
        Object mn = filters.get(minKey);
        Object mx = filters.get(maxKey);
        if (mn instanceof Number n1 && mx instanceof Number n2) {
            if (n2.doubleValue() < n1.doubleValue()) {
                throw new IllegalStateException(
                    maxKey + " (" + n2 + ") must be >= "
                    + minKey + " (" + n1 + ")");
            }
        }
    }

    /** Return a copy of the accumulated filter map. Empty when no
     *  setters have been called. */
    public Map<String, Object> build() {
        return new LinkedHashMap<>(filters);
    }

    /** {@code true} when no filters have been added. */
    public boolean isEmpty() { return filters.isEmpty(); }

    public int size() { return filters.size(); }
}
