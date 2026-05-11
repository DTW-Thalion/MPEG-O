/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import htsjdk.samtools.SAMSequenceRecord;
import htsjdk.samtools.SamReaderFactory;
import htsjdk.samtools.ValidationStringency;
import htsjdk.samtools.cram.ref.CRAMReferenceSource;
import htsjdk.samtools.reference.FastaSequenceFile;
import htsjdk.samtools.reference.ReferenceSequence;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
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
        // htsjdk's stock ReferenceSource uses IndexedFastaSequenceFile
        // with strict @SQ LN + MD5 validation. samtools-produced CRAMs
        // often have placeholder LN or stale M5 hashes that fail this
        // gate. Use an in-memory CRAMReferenceSource that just reads
        // the FASTA bases once and serves them by sequence name — no
        // length/MD5 cross-check, parity with samtools' lenient behavior.
        return SamReaderFactory.makeDefault()
            .validationStringency(ValidationStringency.LENIENT)
            .referenceSource(new InMemoryFastaReferenceSource(referenceFasta));
    }

    /**
     * Minimal CRAMReferenceSource that loads the FASTA bases into a map
     * at construction and serves them by name lookup. Bypasses htsjdk's
     * IndexedFastaSequenceFile strictness (length/MD5 validation, .dict
     * sidecar requirement) so existing samtools-produced CRAMs decode.
     */
    static final class InMemoryFastaReferenceSource implements CRAMReferenceSource {
        private final Map<String, byte[]> sequences = new HashMap<>();

        InMemoryFastaReferenceSource(Path fastaPath) {
            try (FastaSequenceFile fasta = new FastaSequenceFile(
                    fastaPath.toFile(), true)) {
                ReferenceSequence seq;
                while ((seq = fasta.nextSequence()) != null) {
                    sequences.put(seq.getName(), seq.getBases());
                }
            }
        }

        @Override
        public byte[] getReferenceBases(SAMSequenceRecord sequenceRecord,
                                        boolean tryNameVariants) {
            String name = sequenceRecord.getSequenceName();
            byte[] bases = sequences.get(name);
            if (bases == null && tryNameVariants) {
                String alt = name.startsWith("chr") ? name.substring(3)
                                                   : "chr" + name;
                bases = sequences.get(alt);
            }
            return bases;
        }

        @Override
        public byte[] getReferenceBasesByRegion(SAMSequenceRecord sequenceRecord,
                                                int zeroBasedStart, int requestedRegionLength) {
            byte[] bases = getReferenceBases(sequenceRecord, true);
            if (bases == null) return null;
            int end = Math.min(zeroBasedStart + requestedRegionLength, bases.length);
            if (zeroBasedStart >= bases.length || end <= zeroBasedStart) {
                return new byte[0];
            }
            byte[] region = new byte[end - zeroBasedStart];
            System.arraycopy(bases, zeroBasedStart, region, 0, region.length);
            return region;
        }
    }
}
