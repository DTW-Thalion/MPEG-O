/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Parsed {@code POST /v1/cohorts/query} response. Mirrors the
 * Python {@code CohortResult} dataclass.
 */
public record CohortResult(
        List<Map<String, Object>> rows,
        String nextCursor,
        String select,
        Map<String, Object> stats) {

    public CohortResult {
        rows = rows == null ? List.of() : List.copyOf(rows);
        stats = stats == null ? Map.of() : Map.copyOf(stats);
    }

    @SuppressWarnings("unchecked")
    public static CohortResult fromJson(Map<String, Object> body) {
        Object rowsObj = body.get("rows");
        List<Map<String, Object>> rows = (rowsObj instanceof List<?> l)
            ? (List<Map<String, Object>>) (List<?>) l
            : List.of();
        Object cursor = body.get("next_cursor");
        Object sel = body.getOrDefault("select", "containers");
        Object stats = body.get("stats");
        return new CohortResult(
            rows,
            cursor instanceof String s ? s : null,
            sel instanceof String s ? s : "containers",
            stats instanceof Map<?, ?> m
                ? (Map<String, Object>) m
                : Collections.emptyMap());
    }
}
