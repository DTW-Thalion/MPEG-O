/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.cohort.AndPredicate;
import global.thalion.ttio.workbench.cohort.CohortPredicate;
import global.thalion.ttio.workbench.cohort.ContainerFieldPredicate;
import global.thalion.ttio.workbench.cohort.NotPredicate;
import global.thalion.ttio.workbench.cohort.OrPredicate;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pure-unit tests for {@link CohortQueryBuilder}'s static
 * {@code buildPredicate} composite construction.
 */
class CohortQueryBuilderTest {

    private static CohortLeafRow leaf(CohortLeafRow.Kind kind,
                                       String field, String op, String value) {
        CohortLeafRow r = new CohortLeafRow();
        r.setKind(kind);
        r.setField(field);
        r.setOp(op);
        r.setRawValue(value);
        return r;
    }

    // ---- AND ----

    @Test
    void andSingleLeafCollapsesToLeaf() {
        CohortPredicate p = CohortQueryBuilder.buildPredicate("AND",
            List.of(leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "alpha")));
        assertInstanceOf(ContainerFieldPredicate.class, p);
    }

    @Test
    void andMultipleLeavesBuildsAndComposite() {
        CohortPredicate p = CohortQueryBuilder.buildPredicate("AND",
            List.of(
                leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "alpha"),
                leaf(CohortLeafRow.Kind.SUBJECT,   "sex",     "eq", "F")));
        assertInstanceOf(AndPredicate.class, p);
    }

    @Test
    void andAllowsPhenotypeAsLeaf() {
        // Phenotype is allowed under AND; restricted only under OR / NOT.
        CohortPredicate p = CohortQueryBuilder.buildPredicate("AND",
            List.of(leaf(CohortLeafRow.Kind.PHENOTYPE, "diagnosis", "eq", "AD")));
        assertNotNull(p);
    }

    // ---- OR ----

    @Test
    void orMultipleLeavesBuildsOrComposite() {
        CohortPredicate p = CohortQueryBuilder.buildPredicate("OR",
            List.of(
                leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "alpha"),
                leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "beta")));
        assertInstanceOf(OrPredicate.class, p);
    }

    @Test
    void orRejectsPhenotypeLeaf() {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            () -> CohortQueryBuilder.buildPredicate("OR", List.of(
                leaf(CohortLeafRow.Kind.PHENOTYPE, "diagnosis", "eq", "AD"))));
        assertTrue(ex.getMessage().contains("phenotype"));
    }

    // ---- NOT ----

    @Test
    void notExactlyOneLeafBuildsNotComposite() {
        CohortPredicate p = CohortQueryBuilder.buildPredicate("NOT",
            List.of(leaf(CohortLeafRow.Kind.CONTAINER, "encrypted", "eq", "true")));
        assertInstanceOf(NotPredicate.class, p);
    }

    @Test
    void notRejectsZeroLeaves() {
        // Empty leaf list also fails the at-least-one rule first;
        // pin via the message contains-check.
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            () -> CohortQueryBuilder.buildPredicate("NOT", List.of()));
        assertTrue(ex.getMessage().contains("at least one"));
    }

    @Test
    void notRejectsMultipleLeaves() {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            () -> CohortQueryBuilder.buildPredicate("NOT", List.of(
                leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "alpha"),
                leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "beta"))));
        assertTrue(ex.getMessage().contains("NOT requires exactly one"));
    }

    @Test
    void notRejectsPhenotypeLeaf() {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
            () -> CohortQueryBuilder.buildPredicate("NOT", List.of(
                leaf(CohortLeafRow.Kind.PHENOTYPE, "diagnosis", "eq", "AD"))));
        assertTrue(ex.getMessage().contains("phenotype"));
    }

    // ---- general ----

    @Test
    void buildPredicateRejectsEmptyLeafList() {
        assertThrows(IllegalStateException.class, () ->
            CohortQueryBuilder.buildPredicate("AND", List.of()));
    }

    @Test
    void buildPredicateRejectsUnknownComposite() {
        assertThrows(IllegalArgumentException.class, () ->
            CohortQueryBuilder.buildPredicate("XOR", List.of(
                leaf(CohortLeafRow.Kind.CONTAINER, "project", "eq", "alpha"))));
    }
}
