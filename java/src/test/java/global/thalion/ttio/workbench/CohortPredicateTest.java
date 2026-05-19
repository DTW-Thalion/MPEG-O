/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.cohort.CohortPredicate;
import global.thalion.ttio.workbench.cohort.CohortQuery;
import global.thalion.ttio.workbench.cohort.CohortResult;
import global.thalion.ttio.workbench.cohort.OrPredicate;
import global.thalion.ttio.workbench.cohort.PhenotypePredicate;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the W3 cohort predicate AST + CohortQuery
 * builder. Mirrors {@code python/tests/workbench/test_cohort.py};
 * the cross-language anchor test pins both sides against the same
 * literal JSON string.
 */
class CohortPredicateTest {

    // ---------------- allow-list constants

    @Test
    void allowListContainerFields() {
        assertEquals(
            java.util.Set.of("project", "owner", "encrypted",
                              "created_at", "updated_at", "uri"),
            CohortPredicate.ALLOWED_CONTAINER_FIELDS);
    }

    @Test
    void allowListOps() {
        assertEquals(
            java.util.Set.of("eq", "ne", "lt", "gt", "le", "ge",
                              "in", "like", "exists"),
            CohortPredicate.ALLOWED_OPS);
    }

    @Test
    void allowListSelect() {
        assertEquals(
            java.util.Set.of("containers", "subjects", "samples"),
            CohortQuery.ALLOWED_SELECT);
    }

    // ---------------- leaves

    @Test
    void containerLeafJson() {
        Map<String, Object> json = CohortPredicate
            .container("project", "eq", "alpha").toJson();
        assertEquals("project", json.get("container_field"));
        assertEquals("eq", json.get("op"));
        assertEquals("alpha", json.get("value"));
    }

    @Test
    void subjectLeafJson() {
        Map<String, Object> json = CohortPredicate
            .subject("birth_year", "gt", 1950).toJson();
        assertEquals("birth_year", json.get("subject_field"));
        assertEquals(1950, json.get("value"));
    }

    @Test
    void existsOpOmitsValue() {
        Map<String, Object> json = CohortPredicate
            .container("uri", "exists", null).toJson();
        assertFalse(json.containsKey("value"));
    }

    @Test
    void leafRejectsUnknownField() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortPredicate.container("not_a_real_column", "eq", "x"));
    }

    @Test
    void leafRejectsUnknownOp() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortPredicate.container("project", "not_an_op", "x"));
    }

    @Test
    void phenotypeRejectsEmptyName() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortPredicate.phenotype("", "eq", "x"));
    }

    // ---------------- composites

    @Test
    void andJson() {
        CohortPredicate p = CohortPredicate.and(
            CohortPredicate.container("project", "eq", "alpha"),
            CohortPredicate.subject("sex", "eq", "F"));
        Map<String, Object> json = p.toJson();
        assertEquals("and", json.get("op"));
        @SuppressWarnings("unchecked")
        List<Object> kids = (List<Object>) json.get("children");
        assertEquals(2, kids.size());
    }

    @Test
    void orRejectsPhenotype() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortPredicate.or(
                CohortPredicate.container("project", "eq", "alpha"),
                CohortPredicate.phenotype("diagnosis", "eq", "X")));
    }

    @Test
    void notRejectsPhenotype() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortPredicate.not(
                CohortPredicate.phenotype("diagnosis", "eq", "X")));
    }

    @Test
    void orRejectsNestedPhenotype() {
        CohortPredicate inner = CohortPredicate.and(
            CohortPredicate.phenotype("diagnosis", "eq", "X"),
            CohortPredicate.container("project", "eq", "alpha"));
        assertThrows(IllegalArgumentException.class,
            () -> CohortPredicate.or(
                CohortPredicate.container("project", "eq", "beta"),
                inner));
    }

    // ---------------- CohortQuery

    @Test
    void cohortQueryMinimal() {
        Map<String, Object> json = CohortQuery.builder()
            .select("containers").build().toJson();
        assertEquals(Map.of("select", "containers"), json);
    }

    @Test
    void cohortQueryFull() {
        CohortQuery q = CohortQuery.builder()
            .select("subjects")
            .predicate(CohortPredicate.subject("birth_year", "gt", 1950))
            .orderBy("subjects.birth_year", true)
            .orderBy("subjects.external_id")
            .limit(250)
            .cursor("opaque")
            .build();
        Map<String, Object> json = q.toJson();
        assertEquals("subjects", json.get("select"));
        assertEquals(250L, json.get("limit"));
        assertEquals("opaque", json.get("cursor"));
        assertNotNull(json.get("predicate"));
        assertNotNull(json.get("order_by"));
    }

    @Test
    void cohortQueryRejectsBadSelect() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortQuery.builder().select("bogus").build());
    }

    @Test
    void cohortQueryRejectsBadLimit() {
        assertThrows(IllegalArgumentException.class,
            () -> CohortQuery.builder().limit(0).build());
        assertThrows(IllegalArgumentException.class,
            () -> CohortQuery.builder().limit(1001).build());
    }

    // ---------------- CohortResult

    @Test
    void cohortResultFromJson() {
        Map<String, Object> in = new LinkedHashMap<>();
        in.put("rows", List.of(Map.of("uri", "uri:tio:a")));
        in.put("next_cursor", "opaque");
        in.put("select", "containers");
        CohortResult r = CohortResult.fromJson(in);
        assertEquals(1, r.rows().size());
        assertEquals("opaque", r.nextCursor());
    }

    // ---------------- cross-language anchor

    @Test
    void crossLanguagePredicateJsonLiteral() {
        // Pinned against the same literal as the Python suite's
        // test_cross_language_predicate_json_literal. Any drift in
        // either client fails both sides simultaneously.
        CohortPredicate p = CohortPredicate.and(
            CohortPredicate.container("project", "eq", "alpha"),
            CohortPredicate.phenotype("diagnosis", "eq", "Alzheimer's"));
        String wire = WorkbenchJson.encode(p.toJson());
        assertEquals(
            "{\"op\":\"and\",\"children\":["
            + "{\"container_field\":\"project\",\"op\":\"eq\",\"value\":\"alpha\"},"
            + "{\"phenotype\":\"diagnosis\",\"op\":\"eq\",\"value\":\"Alzheimer's\"}]}",
            wire);
    }
}
