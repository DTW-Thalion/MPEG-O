/*
 * MPEG-O Java Implementation — v0.10 M68.5.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.transport;

import com.dtwthalion.mpgo.MiniJson;

import java.util.Map;

/**
 * Server-side filter predicate applied to every {@link AccessUnit}
 * before serialisation. Wire mapping matches Python
 * {@code mpeg_o.transport.filters.AUFilter} and ObjC
 * {@code MPGOAUFilter}.
 */
public final class AUFilter {

    public final Double rtMin;
    public final Double rtMax;
    public final Integer msLevel;
    public final Double precursorMzMin;
    public final Double precursorMzMax;
    public final Integer polarity;  // wire polarity: 0=pos, 1=neg, 2=unknown
    public final Integer datasetId;
    public final Integer maxAu;

    public AUFilter() {
        this(null, null, null, null, null, null, null, null);
    }

    public AUFilter(Double rtMin, Double rtMax, Integer msLevel,
                     Double precursorMzMin, Double precursorMzMax,
                     Integer polarity, Integer datasetId, Integer maxAu) {
        this.rtMin = rtMin;
        this.rtMax = rtMax;
        this.msLevel = msLevel;
        this.precursorMzMin = precursorMzMin;
        this.precursorMzMax = precursorMzMax;
        this.polarity = polarity;
        this.datasetId = datasetId;
        this.maxAu = maxAu;
    }

    /** Parse {@code {"type":"query","filters":{...}}} into an AUFilter. */
    public static AUFilter fromQueryJson(String json) {
        if (json == null || json.isBlank()) return new AUFilter();
        Object parsed = MiniJson.parse(json);
        if (!(parsed instanceof Map<?, ?> outer)) return new AUFilter();
        Object filters = outer.get("filters");
        if (!(filters instanceof Map<?, ?> m)) return new AUFilter();
        @SuppressWarnings("unchecked")
        Map<String, Object> fm = (Map<String, Object>) m;
        return new AUFilter(
                asDouble(fm.get("rt_min")),
                asDouble(fm.get("rt_max")),
                asInt(fm.get("ms_level")),
                asDouble(fm.get("precursor_mz_min")),
                asDouble(fm.get("precursor_mz_max")),
                asInt(fm.get("polarity")),
                asInt(fm.get("dataset_id")),
                asInt(fm.get("max_au"))
        );
    }

    public boolean matches(AccessUnit au, int datasetIdArg) {
        if (datasetId != null && datasetIdArg != datasetId) return false;
        if (rtMin != null && au.retentionTime < rtMin) return false;
        if (rtMax != null && au.retentionTime > rtMax) return false;
        if (msLevel != null && au.msLevel != msLevel) return false;
        if (precursorMzMin != null && au.precursorMz < precursorMzMin) return false;
        if (precursorMzMax != null && au.precursorMz > precursorMzMax) return false;
        if (polarity != null && au.polarity != polarity) return false;
        return true;
    }

    private static Double asDouble(Object o) {
        if (o == null) return null;
        if (o instanceof Number n) return n.doubleValue();
        try { return Double.parseDouble(o.toString()); }
        catch (Exception e) { return null; }
    }

    private static Integer asInt(Object o) {
        if (o == null) return null;
        if (o instanceof Number n) return n.intValue();
        try { return Integer.parseInt(o.toString()); }
        catch (Exception e) { return null; }
    }
}
