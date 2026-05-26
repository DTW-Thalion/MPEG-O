/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.Map;
import java.util.TreeMap;

/**
 * A study Subject: the donor / patient / animal / object the sample
 * was drawn from. First-class TTI-O entity (Stage 6 / Deferral 2,
 * transport-spec v0.11). Persisted as
 * {@code /study/subjects/<external_id>/} per design spec
 * {@code 2026-05-26-subjects-samples-design.md} §4.1 / §5.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOSubject}, Python {@code ttio.subject.Subject}.</p>
 *
 * @param externalId   Stable, depositor-controlled identifier; primary
 *                     key within the dataset. Required, non-empty, must
 *                     not contain {@code '/'} (HDF5 group-name
 *                     restriction, see format-spec §11).
 * @param project      Study acronym / cohort identifier. Free string.
 *                     {@code ""} = unset.
 * @param sex          Free string (e.g. {@code "M"}, {@code "F"},
 *                     {@code "NA"}). No enumeration enforced.
 *                     {@code ""} = unset.
 * @param birthYear    Four-digit year of birth, or {@code 0} sentinel
 *                     for unknown. Stored as int64 on disk; widened to
 *                     int32 in the SUBJECT_METADATA Arrow transport
 *                     payload (column-width consistency with the
 *                     identification table).
 * @param attributes   Open extension slot. Keys are free strings;
 *                     values are stringified. Serialised to disk as a
 *                     sort-keys JSON object so the bytes are
 *                     deterministic across Python / ObjC / Java.
 */
public record Subject(
    String externalId,
    String project,
    String sex,
    long birthYear,
    Map<String, String> attributes
) {
    public Subject {
        if (externalId == null || externalId.isEmpty()) {
            throw new IllegalArgumentException(
                "Subject.externalId must be non-empty");
        }
        if (externalId.contains("/")) {
            throw new IllegalArgumentException(
                "Subject.externalId may not contain '/': " + externalId);
        }
        project = project != null ? project : "";
        sex = sex != null ? sex : "";
        attributes = attributes != null ? Map.copyOf(attributes) : Map.of();
    }

    /**
     * @return JSON serialisation of {@link #attributes} with sorted
     *         keys. Matches Python {@code json.dumps(d, sort_keys=True,
     *         separators=(',', ':'))} and ObjC
     *         {@code NSJSONWritingSortedKeys} byte-for-byte — required
     *         for cross-language transport-spec v0.11 conformance.
     *         Returns {@code "{}"} for an empty map.
     */
    public String attributesJson() {
        if (attributes.isEmpty()) return "{}";
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (var e : new TreeMap<>(attributes).entrySet()) {
            if (!first) sb.append(",");
            sb.append("\"").append(e.getKey()).append("\":\"")
              .append(e.getValue().replace("\"", "\\\"")).append("\"");
            first = false;
        }
        return sb.append("}").toString();
    }
}
