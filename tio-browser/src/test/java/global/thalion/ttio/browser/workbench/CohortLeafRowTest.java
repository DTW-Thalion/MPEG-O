/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.cohort.CohortPredicate;
import global.thalion.ttio.workbench.cohort.ContainerFieldPredicate;
import global.thalion.ttio.workbench.cohort.PhenotypePredicate;
import global.thalion.ttio.workbench.cohort.SampleFieldPredicate;
import global.thalion.ttio.workbench.cohort.SubjectFieldPredicate;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class CohortLeafRowTest {

    // ---- coerceValue ----

    @Test
    void coerceValueParsesIntegers() {
        assertEquals(42L, CohortLeafRow.coerceValue("42", "eq"));
        assertEquals(-1L, CohortLeafRow.coerceValue("-1", "eq"));
    }

    @Test
    void coerceValueParsesDoubles() {
        assertEquals(12.5, CohortLeafRow.coerceValue("12.5", "lt"));
        assertEquals(-0.25, CohortLeafRow.coerceValue("-0.25", "lt"));
    }

    @Test
    void coerceValueParsesBooleans() {
        assertEquals(Boolean.TRUE, CohortLeafRow.coerceValue("true", "eq"));
        assertEquals(Boolean.FALSE, CohortLeafRow.coerceValue("false", "eq"));
        assertEquals(Boolean.TRUE, CohortLeafRow.coerceValue("TRUE", "eq"));
    }

    @Test
    void coerceValueFallsBackToString() {
        assertEquals("alpha", CohortLeafRow.coerceValue("alpha", "eq"));
        assertEquals("Alzheimer's",
            CohortLeafRow.coerceValue("Alzheimer's", "eq"));
    }

    @Test
    void coerceValueExistsAcceptsBlankAsTrue() {
        assertEquals(Boolean.TRUE, CohortLeafRow.coerceValue("", "exists"));
        assertEquals(Boolean.TRUE, CohortLeafRow.coerceValue(null, "exists"));
    }

    @Test
    void coerceValueInBuildsList() {
        Object out = CohortLeafRow.coerceValue("alpha, beta, 42", "in");
        assertTrue(out instanceof List<?>);
        List<?> list = (List<?>) out;
        assertEquals(3, list.size());
        assertEquals("alpha", list.get(0));
        assertEquals("beta", list.get(1));
        assertEquals(42L, list.get(2));
    }

    @Test
    void coerceValueInEmptyIsEmptyList() {
        Object out = CohortLeafRow.coerceValue("", "in");
        assertTrue(out instanceof List<?>);
        assertTrue(((List<?>) out).isEmpty());
    }

    // ---- toPredicate ----

    @Test
    void toPredicateBuildsContainerLeaf() {
        CohortLeafRow row = new CohortLeafRow();
        row.setKind(CohortLeafRow.Kind.CONTAINER);
        row.setField("project");
        row.setOp("eq");
        row.setRawValue("alpha");
        CohortPredicate p = row.toPredicate();
        assertInstanceOf(ContainerFieldPredicate.class, p);
    }

    @Test
    void toPredicateBuildsSubjectLeaf() {
        CohortLeafRow row = new CohortLeafRow();
        row.setKind(CohortLeafRow.Kind.SUBJECT);
        row.setField("sex");
        row.setOp("eq");
        row.setRawValue("F");
        assertInstanceOf(SubjectFieldPredicate.class, row.toPredicate());
    }

    @Test
    void toPredicateBuildsSampleLeaf() {
        CohortLeafRow row = new CohortLeafRow();
        row.setKind(CohortLeafRow.Kind.SAMPLE);
        row.setField("sample_kind");
        row.setOp("eq");
        row.setRawValue("plasma");
        assertInstanceOf(SampleFieldPredicate.class, row.toPredicate());
    }

    @Test
    void toPredicateBuildsPhenotypeLeaf() {
        CohortLeafRow row = new CohortLeafRow();
        row.setKind(CohortLeafRow.Kind.PHENOTYPE);
        row.setField("diagnosis");
        row.setOp("eq");
        row.setRawValue("Alzheimer's");
        assertInstanceOf(PhenotypePredicate.class, row.toPredicate());
    }

    @Test
    void toPredicateRejectsBlankField() {
        CohortLeafRow row = new CohortLeafRow();
        row.setKind(CohortLeafRow.Kind.CONTAINER);
        row.setField("");
        row.setOp("eq");
        row.setRawValue("x");
        assertThrows(IllegalArgumentException.class, row::toPredicate);
    }

    // ---- Kind label round-trip ----

    @Test
    void kindLabelRoundTrip() {
        for (CohortLeafRow.Kind k : CohortLeafRow.Kind.values()) {
            assertSame(k, CohortLeafRow.Kind.fromLabel(k.label()));
        }
    }

    @Test
    void kindFromLabelRejectsUnknown() {
        assertThrows(IllegalArgumentException.class, () ->
            CohortLeafRow.Kind.fromLabel("not-a-kind"));
    }
}
