/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.MzTabReader;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for mzTab. Mirrors the GUI
 *  {@code ImportTask.importMzTab}: an mzTab document yields no
 *  {@code AcquisitionRun}s — only {@link ImportedDataset#identifications}
 *  and {@link ImportedDataset#quantifications}, with the document title
 *  carried over to {@link ImportedDataset#title}. */
public final class MzTabReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        MzTabReader.MzTabImport im = MzTabReader.read(
            Path.of(inputs.get(0)),
            progress != null ? progress : ProgressSink.discard());
        ImportedDataset d = new ImportedDataset();
        if (im.title() != null) d.title = im.title();
        d.identifications.addAll(im.identifications());
        d.quantifications.addAll(im.quantifications());
        return d;
    }
}
