/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

/**
 * A single controlled-vocabulary parameter reference. Immutable
 * value class.
 *
 * <p>In the form
 * {@code (ontologyRef, accession, name, [value], [unit])}. The
 * {@code accession} follows the {@code <CV>:<id>} form used by
 * PSI-MS (e.g. {@code "MS:1000515"}) or nmrCV
 * (e.g. {@code "NMR:1000002"}).</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOCVParam}, Python
 * {@code ttio.cv_param.CVParam}.</p>
 *
 * @param ontologyRef Ontology short name ({@code "MS"}, {@code "NMR"}).
 * @param accession   Ontology accession in {@code <CV>:<id>} form.
 * @param name        Human-readable label.
 * @param value       Optional free-form value; empty string when none.
 * @param unit        Optional unit accession; {@code null} when none.
 *
 */
public record CVParam(
    String ontologyRef,
    String accession,
    String name,
    String value,
    String unit
) {}
