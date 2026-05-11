/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import htsjdk.samtools.SAMFileHeader;
import htsjdk.samtools.SAMFileWriter;
import htsjdk.samtools.SAMFileWriterFactory;

import java.nio.file.Path;
import java.util.Objects;

/**
 * CRAM exporter — M88.
 *
 * <p>v1.5.0 swapped the samtools subprocess for htsjdk's pure-Java CRAM
 * writer. Reference FASTA is still required (CRAM is reference-
 * compressed) — htsjdk's {@link ReferenceSource} reads the FASTA at
 * write time to compute the per-base deltas.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.exporters.cram.CramWriter},
 * Objective-C {@code TTIOCramWriter}.</p>
 *
 * (M88, v1.5.0 htsjdk swap)
 */
public class CramWriter extends BamWriter {

    private final Path referenceFasta;

    /**
     * Construct a {@code CramWriter}.
     *
     * @param path           output CRAM file path.
     * @param referenceFasta filesystem path to the reference FASTA.
     *                       CRAM is reference-compressed; the writer
     *                       reads the FASTA at write time (to compute
     *                       the deltas) and the reader needs the same
     *                       FASTA available at decode time.
     */
    public CramWriter(Path path, Path referenceFasta) {
        super(path);
        this.referenceFasta = Objects.requireNonNull(referenceFasta,
            "referenceFasta is required for CramWriter");
    }

    /** @return the reference FASTA path passed at construction time. */
    public Path referenceFasta() { return referenceFasta; }

    @Override
    protected SAMFileWriter makeWriter(SAMFileHeader header, boolean sort) {
        SAMFileWriterFactory factory = new SAMFileWriterFactory()
            .setCreateIndex(false)
            .setCreateMd5File(false);
        boolean presorted = !sort;
        return factory.makeCRAMWriter(header, presorted,
            path().toFile(), referenceFasta.toFile());
    }
}
