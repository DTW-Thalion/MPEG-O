/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.cohort;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class OrPredicate extends CohortPredicate {

    private final List<CohortPredicate> children;

    public OrPredicate(List<CohortPredicate> children) {
        if (children == null || children.isEmpty()) {
            throw new IllegalArgumentException("OR requires at least one child");
        }
        for (CohortPredicate p : children) {
            if (p.containsPhenotype()) {
                throw new IllegalArgumentException(
                    "phenotype leaves cannot appear under OR (server "
                    + "rejects with 422 -- column joins can't reason "
                    + "about NULL the same way as structural fields)");
            }
        }
        this.children = List.copyOf(children);
    }

    public List<CohortPredicate> children() { return children; }

    @Override
    public Map<String, Object> toJson() {
        Map<String, Object> out = orderedMap();
        out.put("op", "or");
        List<Object> kids = new ArrayList<>(children.size());
        for (CohortPredicate p : children) kids.add(p.toJson());
        out.put("children", kids);
        return out;
    }

    @Override
    boolean containsPhenotype() {
        return false;  // ctor would have rejected
    }
}
