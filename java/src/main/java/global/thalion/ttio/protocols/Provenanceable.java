/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protocols;

import global.thalion.ttio.ProvenanceRecord;

import java.util.List;

/**
 * Objects implementing {@code Provenanceable} carry a W3C
 * PROV-compatible chain of processing records. Every transformation
 * applied to the data contributes an entry; the chain makes the
 * object self-documenting and supports regulatory audit trails.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOProvenanceable}, Python
 * {@code ttio.protocols.Provenanceable}.</p>
 *
 * @since 0.6
 */
public interface Provenanceable {

    /** Append a processing step to the chain. */
    void addProcessingStep(ProvenanceRecord step);

    /** @return the chain in insertion order. */
    List<ProvenanceRecord> provenanceChain();

    /** @return distinct input entity identifiers referenced by the chain. */
    List<String> inputEntities();

    /** @return distinct output entity identifiers referenced by the chain. */
    List<String> outputEntities();
}
