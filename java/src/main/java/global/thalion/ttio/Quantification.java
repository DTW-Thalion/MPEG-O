/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

/**
 * An abundance observation for a chemical entity in a sample.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOQuantification}, Python
 * {@code ttio.quantification.Quantification}.</p>
 *
 * @param chemicalEntity      CHEBI accession or chemical formula.
 * @param sampleRef           Sample identifier.
 * @param abundance           Measured abundance.
 * @param normalizationMethod Normalization method; may be {@code null}
 *                            or empty when unnormalized.
 * @param unit                Free-form unit label for {@link #abundance()}
 *                            (e.g. {@code "ng/mL"}, {@code "peak-area"},
 *                            {@code "ion-count"}, {@code "normalized"}).
 *                            Empty when not specified — readers should
 *                            interpret an empty unit as "implied by
 *                            {@code normalizationMethod}".
 */
public record Quantification(
    String chemicalEntity,
    String sampleRef,
    double abundance,
    String normalizationMethod,
    String unit
) {
    public Quantification {
        if (unit == null) unit = "";
    }

    /**
     * Pre-unit constructor; defaults {@code unit} to {@code ""}. Retained
     * so that callers compiled against the 4-component record continue
     * to work without source changes.
     */
    public Quantification(String chemicalEntity, String sampleRef,
                          double abundance, String normalizationMethod) {
        this(chemicalEntity, sampleRef, abundance, normalizationMethod, "");
    }
}
