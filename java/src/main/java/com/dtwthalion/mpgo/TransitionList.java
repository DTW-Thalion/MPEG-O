/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.util.List;

/**
 * Ordered list of SRM/MRM transitions. Stored as a single
 * JSON-encoded string attribute under {@code /study/transitions/}.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOTransitionList}, Python
 * {@code mpeg_o.transition_list.TransitionList}.</p>
 *
 * @since 0.6
 */
public record TransitionList(List<Transition> transitions) {

    public TransitionList {
        transitions = transitions != null ? List.copyOf(transitions) : List.of();
    }

    /** @return the number of transitions. */
    public int count() { return transitions.size(); }

    /** @return the transition at {@code index}. */
    public Transition transitionAtIndex(int index) { return transitions.get(index); }

    /**
     * One SRM/MRM transition.
     *
     * @param precursorMz         Precursor m/z.
     * @param productMz           Product m/z.
     * @param collisionEnergy     Collision energy (eV).
     * @param retentionTimeWindow Optional RT acceptance window; may be {@code null}.
     */
    public record Transition(double precursorMz, double productMz,
                             double collisionEnergy,
                             ValueRange retentionTimeWindow) {}

    /** Serialize to JSON for the {@code @transitions_json} attribute. */
    public String toJson() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < transitions.size(); i++) {
            if (i > 0) sb.append(",");
            var t = transitions.get(i);
            sb.append("{\"precursor_mz\":").append(t.precursorMz())
              .append(",\"product_mz\":").append(t.productMz())
              .append(",\"collision_energy\":").append(t.collisionEnergy());
            if (t.retentionTimeWindow() != null) {
                sb.append(",\"rt_min\":").append(t.retentionTimeWindow().minimum())
                  .append(",\"rt_max\":").append(t.retentionTimeWindow().maximum());
            }
            sb.append("}");
        }
        return sb.append("]").toString();
    }
}
