/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.BamWriter;
import global.thalion.ttio.exporters.RunSelection;
import global.thalion.ttio.exporters.Writer;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;

/**
 * {@link Writer} adapter for BAM export. Mirrors the tio-browser GUI
 * {@code ExportTask.exportBamLike(false, ...)}: select the genomic run,
 * convert read-side {@link GenomicRun} to write-side
 * {@link WrittenGenomicRun} via the shared {@link RunSelection#toWritten},
 * then {@code new BamWriter(output).write(written, ds.provenanceRecords(),
 * /*sort=*&#47;true, sink)}. Matches Python
 * {@code ttio.exporters.writers.BamWriter}.
 *
 * @since 1.7.0
 */
public final class BamWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        GenomicRun run = RunSelection.genomicRun(ds, layer);
        // GUI: new BamWriter(targetPath).write(w, provenance, /*sort=*/true, sink).
        new BamWriter(output).write(run, ds.provenanceRecords(), true, null);
    }
}
