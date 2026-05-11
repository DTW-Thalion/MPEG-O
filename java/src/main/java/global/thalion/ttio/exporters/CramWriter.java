/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import global.thalion.ttio.importers.CramReader;

import htsjdk.samtools.CRAMFileWriter;
import htsjdk.samtools.SAMFileHeader;
import htsjdk.samtools.SAMFileWriter;
import htsjdk.samtools.SAMSequenceDictionary;
import htsjdk.samtools.SAMSequenceRecord;
import htsjdk.samtools.reference.FastaSequenceFile;
import htsjdk.samtools.reference.ReferenceSequence;

import java.io.BufferedOutputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
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
        Map<String, Integer> refLengths = scanFastaLengths();
        SAMSequenceDictionary updated = new SAMSequenceDictionary();
        for (SAMSequenceRecord seq : header.getSequenceDictionary().getSequences()) {
            Integer realLen = refLengths.get(seq.getSequenceName());
            if (realLen == null) {
                throw new IllegalStateException(
                    "Chromosome '" + seq.getSequenceName()
                    + "' in run not found in reference FASTA "
                    + referenceFasta + " (CRAM is reference-compressed;"
                    + " every emitted @SQ must be in the reference).");
            }
            updated.addSequence(new SAMSequenceRecord(
                seq.getSequenceName(), realLen));
        }
        header.setSequenceDictionary(updated);
        return header;
    }

    /**
     * Scan the reference FASTA and return a map of sequence name → length.
     * Build the dictionary from the FASTA itself rather than requiring a
     * {@code .dict} sidecar, so test fixtures and casual users with bare
     * FASTAs aren't blocked.
     */
    private Map<String, Integer> scanFastaLengths() {
        Map<String, Integer> lengths = new HashMap<>();
        try (FastaSequenceFile fasta = new FastaSequenceFile(
                referenceFasta.toFile(), true)) {
            ReferenceSequence seq;
            while ((seq = fasta.nextSequence()) != null) {
                lengths.put(seq.getName(), seq.length());
            }
        }
        return lengths;
    }

    @Override
    protected SAMFileWriter makeWriter(SAMFileHeader header, boolean sort) {
        // Direct instantiation of CRAMFileWriter with an in-memory
        // reference source so we bypass htsjdk's stock ReferenceSource
        // (which needs .dict + strict length/MD5 validation). Mirrors
        // CramReader's approach so write + read are symmetric.
        boolean presorted = !sort;
        try {
            OutputStream out = new BufferedOutputStream(
                new FileOutputStream(path().toFile()));
            // CRAMFileWriter 6-arg ctor: (OutputStream out, OutputStream
            // indexOS, boolean presorted, CRAMReferenceSource source,
            // SAMFileHeader header, String fileName). We don't write a
            // .crai sidecar — pass null for the index stream.
            return new CRAMFileWriter(
                out,
                null,
                presorted,
                new CramReader.InMemoryFastaReferenceSource(referenceFasta),
                header,
                path().toFile().getName());
        } catch (IOException e) {
            throw new UncheckedIOException(
                "Failed to open CRAM output: " + path(), e);
        }
    }
}
