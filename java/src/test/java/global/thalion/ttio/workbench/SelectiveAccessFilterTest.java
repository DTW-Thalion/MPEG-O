/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.transport.SelectiveAccessFilter;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link SelectiveAccessFilter}. Pure data; no
 * daemon required.
 *
 * <p>Cross-language anchor: {@link #canonicalFilterAnchor()} pins
 * the same builder input as the Python
 * {@code test_selective_access.test_canonical_filter_anchor}.
 * Drift in either client fails both suites.</p>
 */
class SelectiveAccessFilterTest {

    // ---- accepting ----

    @Test
    void msLevelAcceptsPositive() {
        Map<String, Object> f = new SelectiveAccessFilter().msLevel(2).build();
        assertEquals(Map.of("ms_level", 2), f);
    }

    @Test
    void polarityAcceptsKnown() {
        assertEquals(Map.of("polarity", "positive"),
            new SelectiveAccessFilter().polarity("positive").build());
        assertEquals(Map.of("polarity", "negative"),
            new SelectiveAccessFilter().polarity("negative").build());
    }

    @Test
    void polarityNullClearsField() {
        SelectiveAccessFilter b = new SelectiveAccessFilter().polarity("positive");
        assertTrue(b.build().containsKey("polarity"));
        b.polarity(null);
        assertFalse(b.build().containsKey("polarity"));
    }

    @Test
    void retentionTimeRange() {
        Map<String, Object> f = new SelectiveAccessFilter()
            .retentionTimeMin(12.5)
            .retentionTimeMax(25.0)
            .validate()
            .build();
        assertEquals(12.5, f.get("retention_time_min"));
        assertEquals(25.0, f.get("retention_time_max"));
    }

    @Test
    void precursorMzRangeAndCharge() {
        Map<String, Object> f = new SelectiveAccessFilter()
            .precursorMzMin(100.0)
            .precursorMzMax(2000.0)
            .precursorCharge(2)
            .validate()
            .build();
        assertEquals(100.0, f.get("precursor_mz_min"));
        assertEquals(2000.0, f.get("precursor_mz_max"));
        assertEquals(2, f.get("precursor_charge"));
    }

    @Test
    void maxAuAccepted() {
        assertEquals(Map.of("max_au", 50),
            new SelectiveAccessFilter().maxAu(50).build());
    }

    @Test
    void emptyBuilder() {
        SelectiveAccessFilter b = new SelectiveAccessFilter();
        assertTrue(b.isEmpty());
        assertEquals(0, b.size());
        assertTrue(b.build().isEmpty());
    }

    // ---- rejecting ----

    @Test
    void msLevelRejectsZeroAndNegative() {
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().msLevel(0));
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().msLevel(-1));
    }

    @Test
    void polarityRejectsUnknown() {
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().polarity("both"));
        // case-sensitive
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().polarity("POSITIVE"));
    }

    @Test
    void rtMinRejectsNegative() {
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().retentionTimeMin(-0.5));
    }

    @Test
    void rtMaxRejectsNegative() {
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().retentionTimeMax(-0.5));
    }

    @Test
    void mzMinRejectsNegative() {
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().precursorMzMin(-0.1));
    }

    @Test
    void maxAuRejectsZero() {
        assertThrows(IllegalArgumentException.class, () ->
            new SelectiveAccessFilter().maxAu(0));
    }

    // ---- cross-key validation ----

    @Test
    void validateCatchesInvertedRtRange() {
        SelectiveAccessFilter b = new SelectiveAccessFilter()
            .retentionTimeMin(20.0)
            .retentionTimeMax(10.0);
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            b::validate);
        assertTrue(ex.getMessage().contains("retention_time_max"));
    }

    @Test
    void validateCatchesInvertedMzRange() {
        SelectiveAccessFilter b = new SelectiveAccessFilter()
            .precursorMzMin(2000.0)
            .precursorMzMax(100.0);
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            b::validate);
        assertTrue(ex.getMessage().contains("precursor_mz_max"));
    }

    @Test
    void validatePassesEqualRange() {
        // rt_max == rt_min is allowed (single retention-time slice).
        new SelectiveAccessFilter()
            .retentionTimeMin(15.0)
            .retentionTimeMax(15.0)
            .validate();
    }

    // ---- cross-language anchor ----

    @Test
    void canonicalFilterAnchor() {
        // Cross-language anchor: this exact builder input must
        // produce a byte-identical filter map in Java and Python.
        // Python mirror: test_selective_access.test_canonical_filter_anchor.
        Map<String, Object> f = new SelectiveAccessFilter()
            .msLevel(2)
            .polarity("positive")
            .retentionTimeMin(12.5)
            .retentionTimeMax(25.0)
            .precursorMzMin(100.0)
            .precursorMzMax(2000.0)
            .precursorCharge(2)
            .maxAu(50)
            .validate()
            .build();
        Map<String, Object> expected = new LinkedHashMap<>();
        expected.put("ms_level",           2);
        expected.put("polarity",           "positive");
        expected.put("retention_time_min", 12.5);
        expected.put("retention_time_max", 25.0);
        expected.put("precursor_mz_min",   100.0);
        expected.put("precursor_mz_max",   2000.0);
        expected.put("precursor_charge",   2);
        expected.put("max_au",             50);
        assertEquals(expected, f);
    }

    @Test
    void allowedPolaritiesSet() {
        assertEquals(java.util.Set.of("positive", "negative"),
            SelectiveAccessFilter.ALLOWED_POLARITIES);
    }
}
