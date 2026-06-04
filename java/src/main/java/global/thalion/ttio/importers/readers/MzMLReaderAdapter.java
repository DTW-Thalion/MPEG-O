/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.MzMLReader;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for mzML. Mirrors the tio-browser GUI
 *  {@code ImportTask.importMzML}: one parsed {@code AcquisitionRun}
 *  added to {@link ImportedDataset#runs}. */
public final class MzMLReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        ImportedDataset d = new ImportedDataset();
        d.runs.add(progress == null
            ? MzMLReader.read(inputs.get(0))
            : MzMLReader.read(inputs.get(0), progress));
        return d;
    }
}
