/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.time.Instant;
import java.util.*;

public record ProvenanceRecord(
    long timestampUnix,
    String software,
    String parametersJson,
    String inputRefsJson,
    String outputRefsJson
) {
    /** Convenience: create with typed parameters and refs. */
    public static ProvenanceRecord of(String software,
                                       Map<String, String> parameters,
                                       List<String> inputRefs,
                                       List<String> outputRefs) {
        return new ProvenanceRecord(
            Instant.now().getEpochSecond(),
            software,
            mapToJson(parameters),
            listToJson(inputRefs),
            listToJson(outputRefs)
        );
    }

    private static String mapToJson(Map<String, String> map) {
        if (map == null || map.isEmpty()) return "{}";
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (var entry : map.entrySet()) {
            if (!first) sb.append(",");
            sb.append("\"").append(entry.getKey()).append("\":\"")
              .append(entry.getValue().replace("\"", "\\\"")).append("\"");
            first = false;
        }
        sb.append("}");
        return sb.toString();
    }

    private static String listToJson(List<String> list) {
        if (list == null || list.isEmpty()) return "[]";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append("\"").append(list.get(i).replace("\"", "\\\"")).append("\"");
        }
        sb.append("]");
        return sb.toString();
    }
}
