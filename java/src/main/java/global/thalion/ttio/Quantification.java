/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
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
 *
 */
public record Quantification(
    String chemicalEntity,
    String sampleRef,
    double abundance,
    String normalizationMethod
) {}
