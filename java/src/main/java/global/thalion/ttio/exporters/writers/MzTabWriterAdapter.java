/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.MzTabWriter;
import global.thalion.ttio.exporters.Writer;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * {@link Writer} adapter for mzTab export. Mirrors the tio-browser GUI
 * {@code ExportTask.exportMzTab} — identifications + quantifications +
 * (empty) features, dialect from {@code config.mzTabDialect}, title from
 * {@code ds.title()} — and Python {@code ttio.exporters.writers.MzTabWriter}.
 *
 * <p>Dialect default {@code "1.0"} matches the GUI {@code ExportConfig}
 * fallback; override via the {@code "dialect"} opt ({@code "1.0"} proteomics
 * or {@code "2.0.0-M"} metabolomics).</p>
 *
 * @since 1.7.0
 */
public final class MzTabWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        Object dialect = opts.get("dialect");
        String version = dialect != null ? dialect.toString() : "1.0";
        // GUI: MzTabWriter.write(targetPath, idents, quants, List.of(),
        //          mzTabDialect, title, "", sink).
        MzTabWriter.write(
            output,
            ds.identifications(),
            ds.quantifications(),
            List.of(),
            version,
            ds.title(),
            "",
            null);
    }
}
