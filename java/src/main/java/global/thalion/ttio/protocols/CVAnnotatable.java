/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protocols;

import global.thalion.ttio.CVParam;

import java.util.List;

/**
 * Objects implementing {@code CVAnnotatable} can be tagged with
 * controlled-vocabulary parameters from any ontology (PSI-MS, nmrCV,
 * CHEBI, BFO, ...). This is the primary extensibility mechanism in
 * TTI-O: the schema stays minimal while semantic richness lives in
 * curated external ontologies.
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOCVAnnotatable}, Python
 * {@code ttio.protocols.CVAnnotatable}.</p>
 *
 * <p><b>API status:</b> Stable (conformers may change; the protocol
 * is frozen for v0.6).</p>
 *
 *
 */
public interface CVAnnotatable {

    /**
     * Attach a {@link CVParam} to this object.
     *
     * @param param the CV parameter to attach; must not be {@code null}
     */
    void addCvParam(CVParam param);

    /**
     * Detach a previously-attached {@link CVParam}. No-op if absent.
     *
     * @param param the CV parameter to remove
     */
    void removeCvParam(CVParam param);

    /** @return every attached {@link CVParam} in insertion order. */
    List<CVParam> allCvParams();

    /**
     * @param accession the ontology accession string (e.g. {@code MS:1000514})
     * @return every attached {@link CVParam} whose {@code accession} matches
     */
    List<CVParam> cvParamsForAccession(String accession);

    /**
     * @param ontologyRef the ontology reference prefix (e.g. {@code MS})
     * @return every attached {@link CVParam} whose {@code ontologyRef} matches
     */
    List<CVParam> cvParamsForOntologyRef(String ontologyRef);

    /**
     * @param accession the ontology accession string to test
     * @return {@code true} iff at least one attached {@link CVParam} matches
     */
    boolean hasCvParamWithAccession(String accession);
}
