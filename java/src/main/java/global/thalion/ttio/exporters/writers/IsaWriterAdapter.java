/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters.writers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.ISAExporter;
import global.thalion.ttio.exporters.Writer;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;
import java.util.Map;

/**
 * {@link Writer} adapter for ISA-Tab / ISA-JSON export. Mirrors the
 * tio-browser GUI {@code ExportTask.exportIsa}: a {@code .json} output suffix
 * switches to {@code ISAExporter.exportJson} (serialised via
 * {@code Files.writeString}); any other suffix is a directory-style
 * {@code ISAExporter.exportTab}. Matches Python
 * {@code ttio.exporters.writers.IsaWriter}'s bundle export.
 *
 * @since 1.7.0
 */
public final class IsaWriterAdapter implements Writer {

    @Override
    public void write(SpectralDataset ds, String layer, Path output,
                      Map<String, Object> opts) throws IOException {
        String name = output.getFileName().toString().toLowerCase(Locale.ROOT);
        if (name.endsWith(".json")) {
            String json = ISAExporter.exportJson(ds);
            Files.writeString(output, json);
        } else {
            ISAExporter.exportTab(ds, output);
        }
    }
}
