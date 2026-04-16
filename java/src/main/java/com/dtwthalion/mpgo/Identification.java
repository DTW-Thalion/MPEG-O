/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.util.List;

public record Identification(
    String runName,
    int spectrumIndex,
    String chemicalEntity,
    double confidenceScore,
    String evidenceChainJson
) {
    /** Convenience: create with a list of evidence strings. */
    public static Identification of(String runName, int spectrumIndex,
                                     String chemicalEntity, double confidenceScore,
                                     List<String> evidenceChain) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < evidenceChain.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append("\"").append(evidenceChain.get(i).replace("\"", "\\\"")).append("\"");
        }
        sb.append("]");
        return new Identification(runName, spectrumIndex, chemicalEntity,
                confidenceScore, sb.toString());
    }
}
