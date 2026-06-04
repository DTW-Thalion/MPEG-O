/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.importers.ThermoRawReader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for Thermo {@code .raw}. Mirrors the GUI
 *  {@code ImportTask.importThermoRaw}: the reader delegates to
 *  ThermoRawFileParser (which emits mzML) and returns a single
 *  {@code AcquisitionRun}. {@code ThermoRawReader.read} accepts no
 *  {@link ProgressSink}, so {@code progress} is intentionally not
 *  threaded (matching the Python {@code _supports_progress=False}). */
public final class ThermoRawReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        ImportedDataset d = new ImportedDataset();
        d.runs.add(ThermoRawReader.read(inputs.get(0)));
        return d;
    }
}
