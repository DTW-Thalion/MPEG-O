/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import java.util.List;
import java.util.Map;

/**
 * A feature-level observation: a peak detected in one run, with
 * retention time + m/z + charge + per-sample abundances.
 *
 * <p>{@code Feature} sits between {@link Identification} (spectrum-level)
 * and {@link Quantification} (entity-level): it is the row-level
 * record required by mzTab's PEP section (peptide-level
 * quantification in the 1.0 proteomics dialect) and by mzTab-M's
 * SMF/SME sections (small-molecule feature + evidence in the
 * 2.0.0-M metabolomics dialect).</p>
 *
 * <p><b>API status:</b> Provisional (v0.12.0 M78).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOFeature}, Python {@code ttio.feature.Feature}.</p>
 *
 * @param featureId              Identifier unique within the file.
 * @param runName                Acquisition run this feature lives in.
 * @param chemicalEntity         Peptide sequence, CHEBI accession,
 *                               chemical name, or formula.
 * @param retentionTimeSeconds   Apex retention time in seconds.
 * @param expMassToCharge        Experimental precursor m/z.
 * @param charge                 Precursor charge state.
 * @param adductIon              Adduct annotation (e.g. {@code [M+H]1+});
 *                               empty for proteomics peptide features.
 * @param abundances             Per-sample abundances keyed by
 *                               sample/study-variable label.
 * @param evidenceRefs           References that support this feature
 *                               (e.g. SME_ID values for metabolomics,
 *                               spectra_ref entries for proteomics).
 * @since 0.12
 */
public record Feature(
    String featureId,
    String runName,
    String chemicalEntity,
    double retentionTimeSeconds,
    double expMassToCharge,
    int charge,
    String adductIon,
    Map<String, Double> abundances,
    List<String> evidenceRefs
) {
    public Feature {
        adductIon = adductIon != null ? adductIon : "";
        abundances = abundances != null ? Map.copyOf(abundances) : Map.of();
        evidenceRefs = evidenceRefs != null ? List.copyOf(evidenceRefs) : List.of();
    }

    /** Minimal constructor; defaults apply to numeric fields and containers. */
    public static Feature of(String featureId, String runName, String chemicalEntity) {
        return new Feature(featureId, runName, chemicalEntity,
            0.0, 0.0, 0, "", Map.of(), List.of());
    }
}
