/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import java.util.List;

/**
 * A spectrum-level chemical-entity identification. Links a spectrum
 * (by its 0-based index within an acquisition run) to a chemical
 * entity with a confidence score and an evidence chain.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOIdentification}, Python
 * {@code ttio.identification.Identification}.</p>
 *
 * @param runName          Acquisition run that contains the spectrum.
 * @param spectrumIndex    0-based position within that run.
 * @param chemicalEntity   CHEBI accession or chemical formula.
 * @param confidenceScore  Score in {@code [0.0, 1.0]}.
 * @param evidenceChain    Ordered list of free-form evidence strings
 *                         (typically CV accession references).
 * @since 0.6
 */
public record Identification(
    String runName,
    int spectrumIndex,
    String chemicalEntity,
    double confidenceScore,
    List<String> evidenceChain
) {
    public Identification {
        evidenceChain = evidenceChain != null ? List.copyOf(evidenceChain) : List.of();
    }

    /** @return JSON serialization of {@link #evidenceChain}. */
    public String evidenceChainJson() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < evidenceChain.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append("\"").append(evidenceChain.get(i).replace("\"", "\\\"")).append("\"");
        }
        sb.append("]");
        return sb.toString();
    }

    /** Backward-compat convenience factory. */
    public static Identification of(String runName, int spectrumIndex,
                                     String chemicalEntity, double confidenceScore,
                                     List<String> evidenceChain) {
        return new Identification(runName, spectrumIndex, chemicalEntity,
            confidenceScore, evidenceChain);
    }
}
