/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.MzMLWriter;
import global.thalion.ttio.exporters.RunSelection;
import global.thalion.ttio.exporters.Writer;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;

/**
 * {@link Writer} adapter for indexed mzML export. Mirrors the tio-browser
 * GUI {@code ExportTask.exportMzML} ({@code MzMLWriter.write(run, path, true,
 * sink)}) and Python {@code ttio.exporters.writers.MzMLWriter}.
 *
 * @since 1.7.0
 */
public final class MzMLWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        AcquisitionRun run = RunSelection.analyticalRun(ds, layer);
        // GUI: MzMLWriter.write(run, targetPath, /*zlib=*/true, sink).
        MzMLWriter.write(run, output.toString(), true, null);
    }
}
