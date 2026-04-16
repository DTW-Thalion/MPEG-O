/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.util.List;

public record TransitionList(List<Transition> transitions) {
    public record Transition(double precursorMz, double productMz,
                             double collisionEnergy, String name) {}

    /** Serialize to JSON for @transitions_json attribute. */
    public String toJson() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < transitions.size(); i++) {
            if (i > 0) sb.append(",");
            var t = transitions.get(i);
            sb.append("{\"precursor_mz\":").append(t.precursorMz())
              .append(",\"product_mz\":").append(t.productMz())
              .append(",\"collision_energy\":").append(t.collisionEnergy())
              .append(",\"name\":\"").append(t.name().replace("\"", "\\\"")).append("\"}");
        }
        sb.append("]");
        return sb.toString();
    }
}
