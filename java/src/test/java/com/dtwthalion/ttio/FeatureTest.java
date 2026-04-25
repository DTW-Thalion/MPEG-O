/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M78: unit tests for the {@link Feature} value class. Mirrors the
 * Python {@code test_m78_feature.py} value-class block: defaults,
 * equality, defensive copy, and null-to-empty coercion.
 */
class FeatureTest {

    @Test
    void defaultsViaOfHelperAreEmptyContainers() {
        Feature f = Feature.of("f1", "run_a", "PEPTIDER");
        assertEquals("f1", f.featureId());
        assertEquals("run_a", f.runName());
        assertEquals("PEPTIDER", f.chemicalEntity());
        assertEquals(0.0, f.retentionTimeSeconds());
        assertEquals(0.0, f.expMassToCharge());
        assertEquals(0, f.charge());
        assertEquals("", f.adductIon());
        assertTrue(f.abundances().isEmpty());
        assertTrue(f.evidenceRefs().isEmpty());
    }

    @Test
    void compactConstructorCoercesNullsToEmpty() {
        Feature f = new Feature("f1", "r", "X",
            0.0, 0.0, 0, null, null, null);
        assertEquals("", f.adductIon());
        assertTrue(f.abundances().isEmpty());
        assertTrue(f.evidenceRefs().isEmpty());
    }

    @Test
    void equalityOnSameFieldValues() {
        Feature a = new Feature("f1", "r", "X",
            0.0, 500.25, 2, "",
            Map.of("s1", 1.0), List.of("e1"));
        Feature b = new Feature("f1", "r", "X",
            0.0, 500.25, 2, "",
            Map.of("s1", 1.0), List.of("e1"));
        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
    }

    @Test
    void defensiveCopyOfCollections() {
        Map<String, Double> mutMap = new HashMap<>();
        mutMap.put("s1", 1.0);
        Feature f = new Feature("f1", "r", "X",
            0.0, 0.0, 0, "", mutMap, List.of());

        // Mutating the source map must not affect the feature.
        mutMap.put("s2", 99.0);
        assertEquals(1, f.abundances().size());
        assertEquals(Double.valueOf(1.0), f.abundances().get("s1"));

        // Returned collections are unmodifiable.
        assertThrows(UnsupportedOperationException.class,
            () -> f.abundances().put("x", 0.0));
        assertThrows(UnsupportedOperationException.class,
            () -> f.evidenceRefs().add("y"));
    }

}
