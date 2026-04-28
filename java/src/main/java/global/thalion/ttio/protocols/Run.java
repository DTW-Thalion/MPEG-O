/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protocols;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.ProvenanceRecord;

import java.util.List;

/**
 * Modality-agnostic surface shared by every run type — mass-spectrometry,
 * NMR, FID, MSImage, and genomic. A "run" is a sequence of measurements
 * (spectra in the MS / NMR / FID case, aligned reads in the genomic case)
 * that share an acquisition mode, instrument context, and provenance
 * chain.
 *
 * <p>Code that wants to operate uniformly on either modality should
 * type-hint against {@code Run} and use only the methods listed below.
 * Modality-specific work (e.g. extracting a CIGAR string from an
 * aligned read, or a precursor m/z from a mass spectrum) requires
 * narrowing via {@code instanceof} to the concrete class.</p>
 *
 * <p>Both {@link global.thalion.ttio.AcquisitionRun} and
 * {@link global.thalion.ttio.genomics.GenomicRun} {@code implement}
 * this interface. Java is nominal-typed so explicit {@code implements}
 * is required (unlike Python's structural Protocol).</p>
 *
 * <p><b>API status:</b> Provisional (Phase 1 abstraction polish, post-M91).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIORun}, Python {@code ttio.protocols.run.Run}.</p>
 *
 * @since 0.11
 */
public interface Run {

    /** Run identifier as stored in the {@code .tio} file
     *  (e.g. {@code "run_0001"} or {@code "genomic_0001"}). */
    String name();

    /** Acquisition mode enum value identifying the instrument /
     *  protocol context. */
    AcquisitionMode acquisitionMode();

    /** Number of measurements in the run. Modality-specific:
     *  spectra for {@link global.thalion.ttio.AcquisitionRun},
     *  aligned reads for
     *  {@link global.thalion.ttio.genomics.GenomicRun}. */
    int count();

    /** Return the i-th measurement. The element type is modality-
     *  specific (Spectrum / AlignedRead) — return type is
     *  {@code Object} because Java has no covariant generic
     *  abstraction over the two element families.
     *
     *  <p>Implementations should raise
     *  {@link IndexOutOfBoundsException} on out-of-bounds indices. */
    Object get(int index);

    /** Per-run provenance records in insertion order. Empty list
     *  when the run has no provenance attached. */
    List<ProvenanceRecord> provenanceChain();
}
