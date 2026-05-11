/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import htsjdk.samtools.SamReaderFactory;
import htsjdk.samtools.ValidationStringency;
import htsjdk.samtools.cram.ref.ReferenceSource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;

/**
 * CRAM importer — M88.
 *
 * <p>v1.5.0 swapped the samtools subprocess for htsjdk's pure-Java CRAM
 * reader. Reference FASTA is still required (CRAM is reference-
 * compressed). htsjdk's {@link ReferenceSource} reads the FASTA at
 * decode time to reconstitute the per-base data.</p>
 *
 * <p>CRAM is the modern reference-compressed sequencing format used
 * by the 1000 Genomes Project, GA4GH RefGet workflows, and clinical
 * pipelines that need ~50% smaller files than BAM. The reference
 * FASTA is a positional constructor argument; no env-var fallback,
 * no RefGet HTTP support.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.importers.cram.CramReader},
 * Objective-C {@code TTIOCramReader}.</p>
 *
 * (M88, v1.5.0 htsjdk swap)
 */
public class CramReader extends BamReader {

    private final Path referenceFasta;

    /**
     * Construct a {@code CramReader}.
     *
     * @param path           filesystem path to a CRAM file (no
     *                       existence check until first
     *                       {@link #toGenomicRun} call).
     * @param referenceFasta filesystem path to the reference FASTA
     *                       against which the CRAM was aligned.
     *                       Required; CRAM is reference-compressed
     *                       and cannot be decoded without it.
     */
    public CramReader(Path path, Path referenceFasta) {
        super(path);
        this.referenceFasta = Objects.requireNonNull(referenceFasta,
            "referenceFasta is required for CramReader");
    }

    /** @return the reference FASTA path passed at construction time. */
    public Path referenceFasta() { return referenceFasta; }

    @Override
    protected SamReaderFactory makeReaderFactory() {
        if (!Files.exists(referenceFasta)) {
            throw new IllegalStateException(
                "Reference FASTA not found: " + referenceFasta);
        }
        return SamReaderFactory.makeDefault()
            .validationStringency(ValidationStringency.LENIENT)
            .referenceSource(new ReferenceSource(referenceFasta.toFile()));
    }
}
