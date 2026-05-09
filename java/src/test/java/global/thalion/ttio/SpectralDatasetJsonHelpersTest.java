/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-bridge unit tests for the package-private static JSON-builder
 * helpers in {@link SpectralDataset} that the existing test suite did
 * not exercise. Both helpers are only invoked from the SQLite-backed
 * attribute-fallback writer path; the bulk of the existing test corpus
 * round-trips identifications/quantifications/provenance through the
 * HDF5 compound-dataset path, never the JSON-attribute fallback.
 *
 * <p>Per docs/superpowers/plans/2026-05-09-coverage-restoration.md J.6.</p>
 */
class SpectralDatasetJsonHelpersTest {

    @Test
    @DisplayName("SpectralDataset.buildQuantificationsJson: empty + populated + null normalization")
    void buildQuantificationsJsonShape() {
        // Empty list → "[]".
        assertEquals("[]",
            SpectralDataset.buildQuantificationsJson(List.of()));

        // Populated list with both branches of normalization_method
        // (null → key omitted; non-null → key + quoted value emitted).
        List<Quantification> quants = List.of(
            new Quantification("CHEBI:15377", "sample_001", 1234.5, null),
            new Quantification("CHEBI:30742", "sample_002", -0.001, "median")
        );
        String json = SpectralDataset.buildQuantificationsJson(quants);

        assertTrue(json.startsWith("[{"), "should start with array+object");
        assertTrue(json.endsWith("}]"), "should end with object+array");
        assertTrue(json.contains("\"chemical_entity\":\"CHEBI:15377\""));
        assertTrue(json.contains("\"sample_ref\":\"sample_001\""));
        assertTrue(json.contains("\"abundance\":1234.5"));

        // First record has null normalization → key absent.
        int firstObjEnd = json.indexOf("},{");
        assertTrue(firstObjEnd > 0, "two records should be comma-separated");
        String firstObj = json.substring(0, firstObjEnd + 1);
        assertFalse(firstObj.contains("normalization_method"),
            "null normalization should omit key in first object: " + firstObj);

        // Second record has "median" → key present.
        assertTrue(json.contains("\"normalization_method\":\"median\""));

        // Single comma between the two records.
        assertEquals(1, countOccurrences(json, "},{"),
            "exactly one record-separator comma between two records");
    }

    @Test
    @DisplayName("SpectralDataset.buildProvenanceJson: empty + populated + nonEmptyJson defaults")
    void buildProvenanceJsonShape() {
        assertEquals("[]",
            SpectralDataset.buildProvenanceJson(List.of()));

        // First record: populated parameters/inputs/outputs → exercises
        // the nonEmptyJson("{...}") "use the record's own JSON" branch.
        Map<String, String> params = new LinkedHashMap<>();
        params.put("threshold", "0.5");
        params.put("mode", "strict");
        ProvenanceRecord populated = new ProvenanceRecord(
            1700000000L, "TTI-O Java 1.0.0",
            params,
            List.of("file:///in.raw"),
            List.of("file:///out.tio"));

        // Second record: empty params/inputs/outputs → exercises
        // the nonEmptyJson(default) "{}" / "[]" fallback branches.
        ProvenanceRecord emptyish = new ProvenanceRecord(
            -42L, "later step",
            Map.of(),
            List.of(),
            List.of());

        String json = SpectralDataset.buildProvenanceJson(
            List.of(populated, emptyish));

        assertTrue(json.startsWith("[{"));
        assertTrue(json.endsWith("}]"));
        assertTrue(json.contains("\"timestamp_unix\":1700000000"));
        assertTrue(json.contains("\"timestamp_unix\":-42"));
        assertTrue(json.contains("TTI-O Java 1.0.0"));

        // Empty params/refs render as "{}" / "[]" (nonEmptyJson default).
        assertTrue(json.contains("\"parameters\":{}"),
            "empty parameters should fall back to {}: " + json);
        assertTrue(json.contains("\"input_refs\":[]"),
            "empty input_refs should fall back to []: " + json);
        assertTrue(json.contains("\"output_refs\":[]"),
            "empty output_refs should fall back to []: " + json);
    }

    private static int countOccurrences(String haystack, String needle) {
        int n = 0;
        int idx = 0;
        while ((idx = haystack.indexOf(needle, idx)) != -1) {
            n++;
            idx += needle.length();
        }
        return n;
    }
}
