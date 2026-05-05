/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * CRAM exporter — M88.
 *
 * <p>Subclass of {@link BamWriter} that overrides the samtools
 * subprocess invocation to emit CRAM (reference-compressed) output
 * instead of BAM. Per the reference FASTA is
 * a positional constructor argument; samtools needs it for both the
 * {@code view -CS} and the {@code sort -O cram} stages.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.exporters.cram.CramWriter},
 * Objective-C {@code TTIOCramWriter}.</p>
 *
 * (M88)
 */
public class CramWriter extends BamWriter {

    private final Path referenceFasta;

    /**
     * Construct a {@code CramWriter}.
     *
     * @param path           output CRAM file path. The {@code .cram}
     *                       extension is honoured by samtools'
     *                       file-format auto-detection (HANDOFF
     *                       Gotcha §165).
     * @param referenceFasta filesystem path to the reference FASTA.
     *                       CRAM is reference-compressed; samtools
     *                       requires the reference both at write
     *                       time (to compute the deltas) and at read
     *                       time (to reconstitute the bases).
     */
    public CramWriter(Path path, Path referenceFasta) {
        super(path);
        this.referenceFasta = Objects.requireNonNull(referenceFasta,
            "referenceFasta is required for CramWriter ()");
    }

    /** @return the reference FASTA path passed at construction time. */
    public Path referenceFasta() { return referenceFasta; }

    @Override
    protected List<String> buildViewCommand(boolean sort) {
        List<String> cmd = new ArrayList<>();
        cmd.add("samtools");
        cmd.add("view");
        cmd.add("-CS");
        cmd.add("--reference");
        cmd.add(referenceFasta.toAbsolutePath().toString());
        if (!sort) {
            cmd.add("-o");
            cmd.add(path().toAbsolutePath().toString());
        }
        cmd.add("-");
        return cmd;
    }

    @Override
    protected List<String> buildSortCommand(boolean sort) {
        if (!sort) return null;
        List<String> cmd = new ArrayList<>();
        cmd.add("samtools");
        cmd.add("sort");
        cmd.add("-O");
        cmd.add("cram");
        cmd.add("--reference");
        cmd.add(referenceFasta.toAbsolutePath().toString());
        cmd.add("-o");
        cmd.add(path().toAbsolutePath().toString());
        cmd.add("-");
        return cmd;
    }
}
