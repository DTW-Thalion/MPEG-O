/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.CramWriter;
import global.thalion.ttio.exporters.RunSelection;
import global.thalion.ttio.exporters.Writer;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;

/**
 * {@link Writer} adapter for CRAM export. Mirrors the tio-browser GUI
 * {@code ExportTask.exportBamLike(true, ...)} and Python
 * {@code ttio.exporters.writers.CramWriter}: require the {@code reference}
 * opt (Python-parity error text when absent), select the genomic run,
 * convert via the shared {@link RunSelection#toWritten}, then
 * {@code new CramWriter(output, reference).write(written,
 * ds.provenanceRecords(), /*sort=*&#47;true, sink)}.
 *
 * @since 1.7.0
 */
public final class CramWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        Object ref = opts.get("reference");
        if (ref == null || ref.toString().isEmpty()) {
            throw new IllegalArgumentException(
                "CRAM export is reference-compressed; pass the reference FASTA "
                + "via --extra --reference <path>");
        }
        Path reference = (ref instanceof Path p) ? p : Path.of(ref.toString());
        GenomicRun run = RunSelection.genomicRun(ds, layer);
        // GUI: new CramWriter(targetPath, reference)
        //          .write(w, provenance, /*sort=*/true, sink).
        new CramWriter(output, reference)
            .write(run, ds.provenanceRecords(), true, null);
    }
}
