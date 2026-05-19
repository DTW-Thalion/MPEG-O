/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.Map;
import java.util.Objects;

/**
 * Phenotype-keyed leaf. Server-side joins to {@code subject_phenotypes}.
 *
 * <p><strong>Cannot appear under OR / NOT composites</strong> --
 * the server rejects with 422 (the column join can't reason about
 * NULL the same way as a structural field).</p>
 */
public final class PhenotypePredicate extends CohortPredicate {

    private final String name;
    private final String op;
    private final Object value;

    public PhenotypePredicate(String name, String op, Object value) {
        Objects.requireNonNull(name, "name");
        if (name.isEmpty()) {
            throw new IllegalArgumentException(
                "phenotype predicate requires a non-empty `name`");
        }
        this.name = name;
        this.op = validateOp(Objects.requireNonNull(op, "op"));
        this.value = value;
    }

    public String name()  { return name;  }
    public String op()    { return op;    }
    public Object value() { return value; }

    @Override
    public Map<String, Object> toJson() {
        Map<String, Object> out = orderedMap();
        out.put("phenotype", name);
        out.put("op", op);
        if (!"exists".equals(op)) out.put("value", value);
        return out;
    }

    @Override
    boolean containsPhenotype() { return true; }
}
