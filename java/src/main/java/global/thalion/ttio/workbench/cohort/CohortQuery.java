/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Full request body for {@code POST /v1/cohorts/query} and
 * {@code POST /v1/cohorts/preview-count}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.cohort.CohortQuery}.</p>
 */
public final class CohortQuery {

    public static final Set<String> ALLOWED_SELECT = Set.of(
        "containers", "subjects", "samples");

    private final String select;
    private final CohortPredicate predicate;
    private final List<OrderBy> orderBy;
    private final int limit;
    private final String cursor;

    private CohortQuery(Builder b) {
        if (!ALLOWED_SELECT.contains(b.select)) {
            throw new IllegalArgumentException(
                "select must be one of " + ALLOWED_SELECT
                + "; got '" + b.select + "'");
        }
        if (b.limit < 1 || b.limit > 1000) {
            throw new IllegalArgumentException(
                "limit must be in [1, 1000]; got " + b.limit);
        }
        this.select = b.select;
        this.predicate = b.predicate;
        this.orderBy = List.copyOf(b.orderBy);
        this.limit = b.limit;
        this.cursor = b.cursor;
    }

    public String select()                  { return select; }
    public CohortPredicate predicate()      { return predicate; }
    public List<OrderBy> orderBy()          { return orderBy; }
    public int limit()                      { return limit; }
    public String cursor()                  { return cursor; }

    /** Serialise to the wire JSON shape. Field order:
     *  select, predicate, order_by, limit (only if !=100), cursor.
     *  Matches the Python serializer byte-for-byte. */
    public Map<String, Object> toJson() {
        Map<String, Object> out = CohortPredicate.orderedMap();
        out.put("select", select);
        if (predicate != null) out.put("predicate", predicate.toJson());
        if (!orderBy.isEmpty()) {
            List<Object> clauses = new ArrayList<>(orderBy.size());
            for (OrderBy o : orderBy) clauses.add(o.toJson());
            out.put("order_by", clauses);
        }
        if (limit != 100) out.put("limit", (long) limit);
        if (cursor != null) out.put("cursor", cursor);
        return out;
    }

    public static Builder builder() { return new Builder(); }

    public static final class Builder {
        private String select = "containers";
        private CohortPredicate predicate;
        private final List<OrderBy> orderBy = new ArrayList<>();
        private int limit = 100;
        private String cursor;

        public Builder select(String s)              { this.select = s; return this; }
        public Builder predicate(CohortPredicate p)  { this.predicate = p; return this; }
        public Builder orderBy(String field)         { this.orderBy.add(new OrderBy(field, false)); return this; }
        public Builder orderBy(String field, boolean descending) {
            this.orderBy.add(new OrderBy(field, descending));
            return this;
        }
        public Builder limit(int n)                  { this.limit = n; return this; }
        public Builder cursor(String c)              { this.cursor = c; return this; }

        public CohortQuery build() { return new CohortQuery(this); }
    }

    /** One {@code order_by} clause: `"table.column"` and a direction. */
    public record OrderBy(String field, boolean descending) {
        public Map<String, Object> toJson() {
            Map<String, Object> out = CohortPredicate.orderedMap();
            out.put("field", field);
            out.put("descending", descending);
            return out;
        }
    }
}
