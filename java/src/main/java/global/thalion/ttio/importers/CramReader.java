/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Objects;

/**
 * CRAM importer — M88.
 *
 * <p>Subclass of {@link BamReader} that reads CRAM (CRAM Reference-
 * compressed Alignment Map) files via the user-installed
 * {@code samtools} binary. The only on-the-wire difference from BAM
 * is that CRAM input requires {@code --reference <fasta>} so the
 * reference-compressed sequence bytes can be reconstituted; SAM
 * text parsing downstream is identical.</p>
 *
 * <p>CRAM is the modern reference-compressed sequencing format used
 * by the 1000 Genomes Project, GA4GH RefGet workflows, and clinical
 * pipelines that need ~50% smaller files than BAM. Per Binding
 * Decision §139 the reference FASTA is a positional constructor
 * argument; no env-var fallback, no RefGet HTTP support in v0.</p>
 *
 * <p>The {@code samtools} binary is a runtime dependency, not a build
 * dependency. Construction succeeds without samtools on PATH;
 * {@link #toGenomicRun(String, String, String)} raises
 * {@link SamtoolsNotFoundException} when samtools cannot be located
 * at first use (Binding Decision §135 from M87).</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.importers.cram.CramReader},
 * Objective-C {@code TTIOCramReader}.</p>
 *
 * @since 0.13 (M88)
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
     *                       Required (Binding Decision §139); CRAM
     *                       is reference-compressed and cannot be
     *                       decoded without it. samtools auto-builds
     *                       a {@code .fai} index alongside the FASTA
     *                       on first use if one isn't present.
     */
    public CramReader(Path path, Path referenceFasta) {
        super(path);
        this.referenceFasta = Objects.requireNonNull(referenceFasta,
            "referenceFasta is required for CramReader (Binding Decision §139)");
    }

    /** @return the reference FASTA path passed at construction time. */
    public Path referenceFasta() { return referenceFasta; }

    @Override
    protected List<String> buildSamtoolsViewCommand(String region) {
        if (!Files.exists(referenceFasta)) {
            throw new IllegalStateException(
                "Reference FASTA not found: " + referenceFasta);
        }
        // Same shape as the BAM reader, plus --reference <fasta>
        // immediately after the "view -h" tokens so samtools can
        // reconstitute reference-compressed sequences.
        List<String> cmd = new java.util.ArrayList<>();
        cmd.add("samtools");
        cmd.add("view");
        cmd.add("-h");
        cmd.add("--reference");
        cmd.add(referenceFasta.toAbsolutePath().toString());
        cmd.add(path().toAbsolutePath().toString());
        if (region != null) {
            cmd.add(region);
        }
        return cmd;
    }
}
