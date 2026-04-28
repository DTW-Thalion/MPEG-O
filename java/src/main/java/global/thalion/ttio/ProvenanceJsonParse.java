/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.ArrayList;
import java.util.List;

/**
 * Phase 1 (post-M91) helper that parses the JSON-array shape used by
 * the per-run {@code provenance_json} attribute on both
 * {@link AcquisitionRun} (MS / NMR) and
 * {@link global.thalion.ttio.genomics.GenomicRun} (genomic) on-disk
 * groups.
 *
 * <p>The shape is intentionally simple — a top-level array of objects
 * with five fixed fields ({@code timestamp_unix}, {@code software},
 * {@code parameters}, {@code input_refs}, {@code output_refs}) — so a
 * regex-driven pass is sufficient. Heavyweight JSON dependencies are
 * not pulled in because the existing TTI-O codebase already avoids
 * them on this hot path (see {@link MiniJson}).</p>
 *
 * <p>Public so the genomic subpackage can share it; intentionally
 * minimal — not a general JSON parser, only the two run-level
 * provenance attributes (write-side {@code AcquisitionRun.writeProvenance}
 * and the genomic equivalent in {@link SpectralDataset}). Callers
 * parsing the matching fields of other on-disk JSON shapes should
 * keep using {@link MiniJson}.</p>
 */
public final class ProvenanceJsonParse {

    private ProvenanceJsonParse() {}

    /** Parse the per-run provenance JSON array into an ordered list of
     *  {@link ProvenanceRecord}. Returns an empty list when the input
     *  is null, blank, or doesn't carry a top-level array. */
    public static List<ProvenanceRecord> parseArray(String json) {
        if (json == null) return List.of();
        String trimmed = json.trim();
        if (!trimmed.startsWith("[")) return List.of();
        int start = trimmed.indexOf('[');
        int end = trimmed.lastIndexOf(']');
        if (end <= start + 1) return List.of();
        String body = trimmed.substring(start + 1, end);
        List<String> objects = splitTopLevelObjects(body);
        List<ProvenanceRecord> out = new ArrayList<>(objects.size());
        for (String obj : objects) {
            if (obj.isBlank()) continue;
            long ts = readLongField(obj, "timestamp_unix");
            String software = readStringField(obj, "software");
            String paramsJson = readObjectField(obj, "parameters");
            String inputRefsJson = readArrayField(obj, "input_refs");
            String outputRefsJson = readArrayField(obj, "output_refs");
            out.add(new ProvenanceRecord(
                ts, software,
                MiniJson.parseStringMap(paramsJson),
                MiniJson.parseArrayOfStrings(inputRefsJson),
                MiniJson.parseArrayOfStrings(outputRefsJson)));
        }
        return out;
    }

    /** Split a JSON array body (the contents between {@code [} and
     *  {@code ]}) into the substrings of each top-level object,
     *  respecting nested braces and string escapes. */
    private static List<String> splitTopLevelObjects(String body) {
        List<String> out = new ArrayList<>();
        int depth = 0;
        int start = -1;
        boolean inString = false;
        boolean escape = false;
        for (int i = 0; i < body.length(); i++) {
            char c = body.charAt(i);
            if (inString) {
                if (escape) { escape = false; continue; }
                if (c == '\\') { escape = true; continue; }
                if (c == '"') inString = false;
                continue;
            }
            if (c == '"') { inString = true; continue; }
            if (c == '{') {
                if (depth == 0) start = i;
                depth++;
            } else if (c == '}') {
                depth--;
                if (depth == 0 && start >= 0) {
                    out.add(body.substring(start, i + 1));
                    start = -1;
                }
            }
        }
        return out;
    }

    private static long readLongField(String obj, String key) {
        String pattern = "\"" + key + "\"";
        int kIdx = obj.indexOf(pattern);
        if (kIdx < 0) return 0L;
        int colon = obj.indexOf(':', kIdx + pattern.length());
        if (colon < 0) return 0L;
        int i = colon + 1;
        while (i < obj.length() && Character.isWhitespace(obj.charAt(i))) i++;
        int s = i;
        while (i < obj.length() && (Character.isDigit(obj.charAt(i))
                || obj.charAt(i) == '-')) i++;
        if (i == s) return 0L;
        try { return Long.parseLong(obj.substring(s, i)); }
        catch (NumberFormatException e) { return 0L; }
    }

    private static String readStringField(String obj, String key) {
        String pattern = "\"" + key + "\"";
        int kIdx = obj.indexOf(pattern);
        if (kIdx < 0) return "";
        int colon = obj.indexOf(':', kIdx + pattern.length());
        if (colon < 0) return "";
        int q1 = obj.indexOf('"', colon + 1);
        if (q1 < 0) return "";
        StringBuilder sb = new StringBuilder();
        boolean escape = false;
        for (int i = q1 + 1; i < obj.length(); i++) {
            char c = obj.charAt(i);
            if (escape) { sb.append(c); escape = false; continue; }
            if (c == '\\') { escape = true; continue; }
            if (c == '"') break;
            sb.append(c);
        }
        return sb.toString();
    }

    private static String readObjectField(String obj, String key) {
        return readBracketedField(obj, key, '{', '}');
    }

    private static String readArrayField(String obj, String key) {
        return readBracketedField(obj, key, '[', ']');
    }

    private static String readBracketedField(
            String obj, String key, char open, char close) {
        String pattern = "\"" + key + "\"";
        int kIdx = obj.indexOf(pattern);
        if (kIdx < 0) return open == '{' ? "{}" : "[]";
        int colon = obj.indexOf(':', kIdx + pattern.length());
        if (colon < 0) return open == '{' ? "{}" : "[]";
        int openIdx = obj.indexOf(open, colon + 1);
        if (openIdx < 0) return open == '{' ? "{}" : "[]";
        int depth = 0;
        boolean inString = false;
        boolean escape = false;
        for (int i = openIdx; i < obj.length(); i++) {
            char c = obj.charAt(i);
            if (inString) {
                if (escape) { escape = false; continue; }
                if (c == '\\') { escape = true; continue; }
                if (c == '"') inString = false;
                continue;
            }
            if (c == '"') { inString = true; continue; }
            if (c == open) depth++;
            else if (c == close) {
                depth--;
                if (depth == 0) return obj.substring(openIdx, i + 1);
            }
        }
        return open == '{' ? "{}" : "[]";
    }
}
