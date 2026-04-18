/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.hdf5.Hdf5Group;
import java.util.*;

/**
 * Reader/writer for MPEG-O feature flags stored as root group attributes.
 * {@code @mpeg_o_format_version = "1.1"}
 * {@code @mpeg_o_features = JSON array of feature strings}
 *
 * @since 0.5
 */
public final class FeatureFlags {
    // Required features (must refuse if unrecognized)
    public static final String BASE_V1 = "base_v1";
    public static final String COMPOUND_IDENTIFICATIONS = "compound_identifications";
    public static final String COMPOUND_QUANTIFICATIONS = "compound_quantifications";
    public static final String COMPOUND_PROVENANCE = "compound_provenance";
    public static final String COMPOUND_PER_RUN_PROVENANCE = "compound_per_run_provenance";

    // Optional features (ignorable if unrecognized)
    public static final String OPT_COMPOUND_HEADERS = "opt_compound_headers";
    public static final String OPT_NATIVE_2D_NMR = "opt_native_2d_nmr";
    public static final String OPT_NATIVE_MSIMAGE_CUBE = "opt_native_msimage_cube";
    public static final String OPT_DATASET_ENCRYPTION = "opt_dataset_encryption";
    public static final String OPT_DIGITAL_SIGNATURES = "opt_digital_signatures";
    public static final String OPT_CANONICAL_SIGNATURES = "opt_canonical_signatures";
    public static final String OPT_KEY_ROTATION = "opt_key_rotation";
    public static final String OPT_ANONYMIZED = "opt_anonymized";
    /** v0.8 M49: file uses post-quantum crypto (ML-KEM-1024 and/or
     *  ML-DSA-87). Opt-flag — a reader without PQC can still open the
     *  file and read unencrypted datasets. @since 0.8 */
    public static final String OPT_PQC_PREVIEW = "opt_pqc_preview";

    private static final Set<String> REQUIRED = Set.of(
        BASE_V1, COMPOUND_IDENTIFICATIONS, COMPOUND_QUANTIFICATIONS,
        COMPOUND_PROVENANCE, COMPOUND_PER_RUN_PROVENANCE
    );

    private static final Set<String> KNOWN_OPTIONAL = Set.of(
        OPT_COMPOUND_HEADERS, OPT_NATIVE_2D_NMR, OPT_NATIVE_MSIMAGE_CUBE,
        OPT_DATASET_ENCRYPTION, OPT_DIGITAL_SIGNATURES, OPT_CANONICAL_SIGNATURES,
        OPT_KEY_ROTATION, OPT_ANONYMIZED, OPT_PQC_PREVIEW
    );

    private final String formatVersion;
    private final Set<String> features;

    public FeatureFlags(String formatVersion, Collection<String> features) {
        this.formatVersion = formatVersion;
        this.features = new LinkedHashSet<>(features);
    }

    public String formatVersion() { return formatVersion; }
    public Set<String> features() { return Collections.unmodifiableSet(features); }
    public boolean has(String flag) { return features.contains(flag); }

    /** Check if this is a v0.1 file (no features attribute). */
    public boolean isV1Legacy() {
        return features.isEmpty() || "1.0.0".equals(formatVersion);
    }

    /** Default features for a new v0.4+ file. */
    public static FeatureFlags defaultCurrent() {
        List<String> flags = new ArrayList<>(REQUIRED);
        return new FeatureFlags("1.1", flags);
    }

    /** Add an optional feature flag. */
    public FeatureFlags with(String flag) {
        Set<String> updated = new LinkedHashSet<>(features);
        updated.add(flag);
        return new FeatureFlags(formatVersion, updated);
    }

    /** Read feature flags from an HDF5 root group. */
    public static FeatureFlags readFrom(Hdf5Group root) {
        String version = "1.0.0";
        Set<String> flags = new LinkedHashSet<>();

        if (root.hasAttribute("mpeg_o_format_version")) {
            version = root.readStringAttribute("mpeg_o_format_version");
        }
        if (root.hasAttribute("mpeg_o_features")) {
            String json = root.readStringAttribute("mpeg_o_features");
            // Parse simple JSON array: ["flag1","flag2",...]
            flags = parseJsonArray(json);
        }
        return new FeatureFlags(version, flags);
    }

    /** Write feature flags to an HDF5 root group. */
    public void writeTo(Hdf5Group root) {
        root.setStringAttribute("mpeg_o_format_version", formatVersion);
        root.setStringAttribute("mpeg_o_features", toJsonArray());
    }

    private String toJsonArray() {
        StringBuilder sb = new StringBuilder("[");
        boolean first = true;
        for (String f : features) {
            if (!first) sb.append(",");
            sb.append("\"").append(f).append("\"");
            first = false;
        }
        sb.append("]");
        return sb.toString();
    }

    static Set<String> parseJsonArray(String json) {
        Set<String> result = new LinkedHashSet<>();
        if (json == null || json.isBlank()) return result;
        // Strip brackets and split by comma
        String inner = json.strip();
        if (inner.startsWith("[")) inner = inner.substring(1);
        if (inner.endsWith("]")) inner = inner.substring(0, inner.length() - 1);
        for (String part : inner.split(",")) {
            String trimmed = part.strip();
            if (trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
                trimmed = trimmed.substring(1, trimmed.length() - 1);
            }
            if (!trimmed.isEmpty()) result.add(trimmed);
        }
        return result;
    }
}
