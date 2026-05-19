/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.Map;
import java.util.Objects;

public final class SubjectFieldPredicate extends CohortPredicate {

    private final String field;
    private final String op;
    private final Object value;

    public SubjectFieldPredicate(String field, String op, Object value) {
        this.field = validateField(
            Objects.requireNonNull(field, "field"),
            ALLOWED_SUBJECT_FIELDS, "subject");
        this.op = validateOp(Objects.requireNonNull(op, "op"));
        this.value = value;
    }

    public String field() { return field; }
    public String op()    { return op;    }
    public Object value() { return value; }

    @Override
    public Map<String, Object> toJson() {
        Map<String, Object> out = orderedMap();
        out.put("subject_field", field);
        out.put("op", op);
        if (!"exists".equals(op)) out.put("value", value);
        return out;
    }

    @Override
    boolean containsPhenotype() { return false; }
}
