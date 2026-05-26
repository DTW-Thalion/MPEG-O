/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.Map;
import java.util.TreeMap;

/**
 * A biological / material Sample collected from a {@link Subject}, or
 * a standalone sample with no recorded subject. First-class TTI-O
 * entity (Stage 6 / Deferral 2, transport-spec v0.11). Persisted as
 * {@code /study/samples/<sample_id>/} per design spec
 * {@code 2026-05-26-subjects-samples-design.md} §4.2 / §5.
 *
 * <p>The {@link #sampleId} matches {@link AcquisitionRun#sampleName()}
 * for the run → sample link; that string remains the canonical link
 * (no breaking change in this stage). When both Sample rows and
 * {@link AcquisitionRun#sampleName()} are present, applications
 * SHOULD treat {@code sampleName} as a foreign key into the Sample
 * list. No automatic enrichment.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOSample}, Python {@code ttio.sample.Sample}.</p>
 *
 * @param sampleId            Stable, depositor-controlled identifier;
 *                            primary key within the dataset.
 *                            Required, non-empty, must not contain
 *                            {@code '/'} (HDF5 group-name restriction,
 *                            see format-spec §11).
 * @param subjectExternalId   Soft foreign key into the Subject list of
 *                            the same dataset. Absent / unset =
 *                            {@code ""}. A mismatch (non-empty value
 *                            but no matching Subject) logs a WARNING
 *                            during create; it is not an error.
 * @param sampleKind          Free string (e.g. {@code "tissue"},
 *                            {@code "plasma"}). {@code ""} = unset.
 * @param collectedAt         Unix seconds since epoch when the sample
 *                            was collected, or {@code 0} sentinel for
 *                            unknown. Stored as int64 on disk and in
 *                            the SAMPLE_METADATA Arrow transport
 *                            payload.
 * @param attributes          Open extension slot. Keys are free
 *                            strings; values are stringified.
 *                            Serialised to disk as a sort-keys JSON
 *                            object so the bytes are deterministic
 *                            across Python / ObjC / Java.
 */
public record Sample(
    String sampleId,
    String subjectExternalId,
    String sampleKind,
    long collectedAt,
    Map<String, String> attributes
) {
    public Sample {
        if (sampleId == null || sampleId.isEmpty()) {
            throw new IllegalArgumentException(
                "Sample.sampleId must be non-empty");
        }
        if (sampleId.contains("/")) {
            throw new IllegalArgumentException(
                "Sample.sampleId may not contain '/': " + sampleId);
        }
        subjectExternalId = subjectExternalId != null ? subjectExternalId : "";
        sampleKind = sampleKind != null ? sampleKind : "";
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
