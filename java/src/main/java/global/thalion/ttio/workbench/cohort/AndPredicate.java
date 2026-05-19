/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class AndPredicate extends CohortPredicate {

    private final List<CohortPredicate> children;

    public AndPredicate(List<CohortPredicate> children) {
        if (children == null || children.isEmpty()) {
            throw new IllegalArgumentException("AND requires at least one child");
        }
        this.children = List.copyOf(children);
    }

    public List<CohortPredicate> children() { return children; }

    @Override
    public Map<String, Object> toJson() {
        Map<String, Object> out = orderedMap();
        out.put("op", "and");
        List<Object> kids = new ArrayList<>(children.size());
        for (CohortPredicate p : children) kids.add(p.toJson());
        out.put("children", kids);
        return out;
    }

    @Override
    boolean containsPhenotype() {
        for (CohortPredicate p : children) {
            if (p.containsPhenotype()) return true;
        }
        return false;
    }
}
