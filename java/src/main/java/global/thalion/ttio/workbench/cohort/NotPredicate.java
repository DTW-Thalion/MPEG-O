/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.Map;
import java.util.Objects;

public final class NotPredicate extends CohortPredicate {

    private final CohortPredicate child;

    public NotPredicate(CohortPredicate child) {
        Objects.requireNonNull(child, "child");
        if (child.containsPhenotype()) {
            throw new IllegalArgumentException(
                "phenotype leaves cannot appear under NOT");
        }
        this.child = child;
    }

    public CohortPredicate child() { return child; }

    @Override
    public Map<String, Object> toJson() {
        Map<String, Object> out = orderedMap();
        out.put("op", "not");
        out.put("child", child.toJson());
        return out;
    }

    @Override
    boolean containsPhenotype() {
        return false;
    }
}
