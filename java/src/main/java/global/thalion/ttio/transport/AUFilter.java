/*
 * TTI-O Java Implementation - v0.10 M68.5 + v0.11 M89.3.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.MiniJson;

import java.util.Map;

/**
 * Server-side filter predicate applied to every {@link AccessUnit}
 * before serialisation. Wire mapping matches Python
 * {@code ttio.transport.filters.AUFilter} and ObjC
 * {@code TTIOAUFilter}.
 *
 * <p>M89.3 (v0.11) added the three genomic predicates:
 * {@link #chromosome} (exact-match string), {@link #positionMin} and
 * {@link #positionMax} (inclusive int64 range). The position
 * predicates explicitly reject non-genomic AUs ({@code spectrumClass
 * != 5}) so MS and genomic AUs in a multiplexed stream remain
 * cleanly separable.</p>
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

    // M89.3 genomic predicates. Optional; null = predicate not applied.
    public final String chromosome;
    public final Long positionMin;
    public final Long positionMax;

    public AUFilter() {
        this(null, null, null, null, null, null, null, null,
             null, null, null);
    }

    /** Backwards-compatible spectral-only constructor. */
    public AUFilter(Double rtMin, Double rtMax, Integer msLevel,
                     Double precursorMzMin, Double precursorMzMax,
                     Integer polarity, Integer datasetId, Integer maxAu) {
        this(rtMin, rtMax, msLevel, precursorMzMin, precursorMzMax,
             polarity, datasetId, maxAu,
             null, null, null);
    }

    /** M89.3 full constructor including genomic predicates. */
    public AUFilter(Double rtMin, Double rtMax, Integer msLevel,
                     Double precursorMzMin, Double precursorMzMax,
                     Integer polarity, Integer datasetId, Integer maxAu,
                     String chromosome, Long positionMin, Long positionMax) {
        this.rtMin = rtMin;
        this.rtMax = rtMax;
        this.msLevel = msLevel;
        this.precursorMzMin = precursorMzMin;
        this.precursorMzMax = precursorMzMax;
        this.polarity = polarity;
        this.datasetId = datasetId;
        this.maxAu = maxAu;
        this.chromosome = chromosome;
        this.positionMin = positionMin;
        this.positionMax = positionMax;
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
        Object chromObj = fm.get("chromosome");
        return new AUFilter(
                asDouble(fm.get("rt_min")),
                asDouble(fm.get("rt_max")),
                asInt(fm.get("ms_level")),
                asDouble(fm.get("precursor_mz_min")),
                asDouble(fm.get("precursor_mz_max")),
                asInt(fm.get("polarity")),
                asInt(fm.get("dataset_id")),
                asInt(fm.get("max_au")),
                chromObj == null ? null : chromObj.toString(),
                asLong(fm.get("position_min")),
                asLong(fm.get("position_max"))
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
        // M89.3 genomic predicates. A genomic predicate set on a
        // non-genomic AU MUST exclude that AU - the two AU types are
        // cleanly separated in multiplexed streams. A non-genomic AU
        // has spectrumClass != 5 and chromosome == "" (the constructor
        // default).
        if (chromosome != null && !chromosome.equals(au.chromosome)) return false;
        if (positionMin != null || positionMax != null) {
            if (au.spectrumClass != 5) {
                // Position filter on an MS AU - exclude.
                return false;
            }
            if (positionMin != null && au.position < positionMin) return false;
            if (positionMax != null && au.position > positionMax) return false;
        }
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

    private static Long asLong(Object o) {
        if (o == null) return null;
        if (o instanceof Number n) return n.longValue();
        try { return Long.parseLong(o.toString()); }
        catch (Exception e) { return null; }
    }
}
