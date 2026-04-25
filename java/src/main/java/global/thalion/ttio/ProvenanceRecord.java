/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * A single provenance step describing how data was produced or
 * transformed. W3C PROV-compatible.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOProvenanceRecord}, Python
 * {@code ttio.provenance.ProvenanceRecord}.</p>
 *
 * @param timestampUnix Unix timestamp (seconds since epoch).
 * @param software      Software name + version.
 * @param parameters    Software-specific processing parameters.
 * @param inputRefs     URIs/identifiers of input entities.
 * @param outputRefs    URIs/identifiers of output entities.
 * @since 0.6
 */
public record ProvenanceRecord(
    long timestampUnix,
    String software,
    Map<String, String> parameters,
    List<String> inputRefs,
    List<String> outputRefs
) {
    public ProvenanceRecord {
        parameters = parameters != null ? Map.copyOf(parameters) : Map.of();
        inputRefs = inputRefs != null ? List.copyOf(inputRefs) : List.of();
        outputRefs = outputRefs != null ? List.copyOf(outputRefs) : List.of();
    }

    /** @return {@code true} iff {@code ref} is in {@link #inputRefs}. */
    public boolean containsInputRef(String ref) {
        return inputRefs.contains(ref);
    }

    /** Convenience factory that sets the current timestamp. */
    public static ProvenanceRecord of(String software,
                                       Map<String, String> parameters,
                                       List<String> inputRefs,
                                       List<String> outputRefs) {
        return new ProvenanceRecord(
            Instant.now().getEpochSecond(),
            software, parameters, inputRefs, outputRefs);
    }

    /** @return JSON serialization of {@link #parameters}. */
    public String parametersJson() {
        if (parameters.isEmpty()) return "{}";
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (var e : parameters.entrySet()) {
            if (!first) sb.append(",");
            sb.append("\"").append(e.getKey()).append("\":\"")
              .append(e.getValue().replace("\"", "\\\"")).append("\"");
            first = false;
        }
        return sb.append("}").toString();
    }

    /** @return JSON serialization of {@link #inputRefs}. */
    public String inputRefsJson() { return listToJson(inputRefs); }

    /** @return JSON serialization of {@link #outputRefs}. */
    public String outputRefsJson() { return listToJson(outputRefs); }

    private static String listToJson(List<String> list) {
        if (list.isEmpty()) return "[]";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append("\"").append(list.get(i).replace("\"", "\\\"")).append("\"");
        }
        return sb.append("]").toString();
    }
}
