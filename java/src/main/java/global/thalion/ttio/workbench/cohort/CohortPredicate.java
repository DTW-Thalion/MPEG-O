/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Abstract cohort-query predicate node. Pure data; no I/O.
 * Each subclass produces a JSON shape matching the workbench
 * server's {@code TTIOWBCohortQuery} wire AST.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.cohort.CohortPredicate}. The JSON output
 * is byte-identical for the same inputs; the cross-language
 * equivalence test pins both sides against the same literals.</p>
 *
 * <p>Helpers (factory methods on this class):</p>
 * <ul>
 *   <li>{@link #container(String, String, Object)}</li>
 *   <li>{@link #subject(String, String, Object)}</li>
 *   <li>{@link #sample(String, String, Object)}</li>
 *   <li>{@link #phenotype(String, String, Object)}</li>
 *   <li>{@link #and(CohortPredicate...)}</li>
 *   <li>{@link #or(CohortPredicate...)}</li>
 *   <li>{@link #not(CohortPredicate)}</li>
 * </ul>
 */
public abstract class CohortPredicate {

    /** Allow-listed leaf fields per the server's TTIOWBCohortQuery.h. */
    public static final Set<String> ALLOWED_CONTAINER_FIELDS = Set.of(
        "project", "owner", "encrypted",
        "created_at", "updated_at", "uri");

    public static final Set<String> ALLOWED_SUBJECT_FIELDS = Set.of(
        "project", "external_id", "sex", "birth_year");

    public static final Set<String> ALLOWED_SAMPLE_FIELDS = Set.of(
        "sample_kind", "collected_at");

    public static final Set<String> ALLOWED_OPS = Set.of(
        "eq", "ne", "lt", "gt", "le", "ge", "in", "like", "exists");

    /** Serialise to the server's JSON shape. */
    public abstract Map<String, Object> toJson();

    /** Does this subtree contain a {@link PhenotypePredicate}? Used
     *  to enforce "phenotype leaves rejected under OR / NOT". */
    abstract boolean containsPhenotype();

    // -------- factories --------

    public static ContainerFieldPredicate container(
            String field, String op, Object value) {
        return new ContainerFieldPredicate(field, op, value);
    }

    public static SubjectFieldPredicate subject(
            String field, String op, Object value) {
        return new SubjectFieldPredicate(field, op, value);
    }

    public static SampleFieldPredicate sample(
            String field, String op, Object value) {
        return new SampleFieldPredicate(field, op, value);
    }

    public static PhenotypePredicate phenotype(
            String name, String op, Object value) {
        return new PhenotypePredicate(name, op, value);
    }

    public static AndPredicate and(CohortPredicate... children) {
        return new AndPredicate(List.of(children));
    }

    public static OrPredicate or(CohortPredicate... children) {
        return new OrPredicate(List.of(children));
    }

    public static NotPredicate not(CohortPredicate child) {
        return new NotPredicate(child);
    }

    // -------- shared validation helpers --------

    static String validateOp(String op) {
        if (!ALLOWED_OPS.contains(op)) {
            throw new IllegalArgumentException(
                "unknown predicate op '" + op + "'; allowed: " + ALLOWED_OPS);
        }
        return op;
    }

    static String validateField(String field, Set<String> allowed, String kind) {
        if (!allowed.contains(field)) {
            throw new IllegalArgumentException(
                "unknown " + kind + " field '" + field + "'; allowed: " + allowed);
        }
        return field;
    }

    /** Build a LinkedHashMap with a stable insertion order so the
     *  emitted JSON matches the Python order byte-for-byte. */
    static Map<String, Object> orderedMap() {
        return new LinkedHashMap<>();
    }
}
