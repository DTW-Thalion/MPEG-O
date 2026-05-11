/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import htsjdk.samtools.SAMFileHeader;
import htsjdk.samtools.SAMFileWriter;
import htsjdk.samtools.SAMFileWriterFactory;
import htsjdk.samtools.SAMSequenceDictionary;
import htsjdk.samtools.SAMSequenceRecord;
import htsjdk.samtools.reference.ReferenceSequenceFile;
import htsjdk.samtools.reference.ReferenceSequenceFileFactory;

import java.nio.file.Path;
import java.util.List;
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

    /**
     * Override to substitute the parent BamWriter's INT32_MAX-placeholder
     * sequence lengths with real lengths from the reference FASTA. htsjdk's
     * CRAM writer validates that SAMSequenceRecord.length matches the
     * reference FASTA at slice-encode time and refuses to write otherwise
     * ("A reference must be supplied (reference sequence ... not found)").
     */
    @Override
    SAMFileHeader buildHeader(WrittenGenomicRun run,
                              List<ProvenanceRecord> provenance,
                              boolean sort) {
        SAMFileHeader header = super.buildHeader(run, provenance, sort);
        try (ReferenceSequenceFile refSeq =
                ReferenceSequenceFileFactory.getReferenceSequenceFile(
                    referenceFasta.toFile())) {
            SAMSequenceDictionary refDict = refSeq.getSequenceDictionary();
            if (refDict == null) {
                throw new IllegalStateException(
                    "Reference FASTA " + referenceFasta + " has no .dict "
                    + "sidecar; CRAM writing requires one. Generate via "
                    + "`samtools dict <fasta>` or htsjdk's "
                    + "CreateSequenceDictionary tool.");
            }
            SAMSequenceDictionary updated = new SAMSequenceDictionary();
            for (SAMSequenceRecord seq : header.getSequenceDictionary().getSequences()) {
                SAMSequenceRecord refRec = refDict.getSequence(seq.getSequenceName());
                if (refRec == null) {
                    throw new IllegalStateException(
                        "Chromosome '" + seq.getSequenceName()
                        + "' in run not found in reference FASTA "
                        + referenceFasta + " (CRAM is reference-compressed;"
                        + " every emitted @SQ must be in the reference).");
                }
                updated.addSequence(new SAMSequenceRecord(
                    refRec.getSequenceName(), refRec.getSequenceLength()));
            }
            header.setSequenceDictionary(updated);
        } catch (java.io.IOException e) {
            throw new IllegalStateException(
                "Failed to read reference FASTA dictionary: " + referenceFasta, e);
        }
        return header;
    }

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
