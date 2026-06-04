/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.NmrMLReader;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for nmrML. Mirrors the GUI
 *  {@code ImportTask.importNmrML}: the parsed {@code NmrMLResult.run()}
 *  is added to {@link ImportedDataset#runs}. */
public final class NmrMLReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        ImportedDataset d = new ImportedDataset();
        NmrMLReader.NmrMLResult result = (progress == null)
            ? NmrMLReader.read(inputs.get(0))
            : NmrMLReader.read(inputs.get(0), progress);
        d.runs.add(result.run());
        return d;
    }
}
