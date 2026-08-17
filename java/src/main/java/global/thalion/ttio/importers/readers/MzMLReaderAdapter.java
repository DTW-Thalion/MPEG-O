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
        java.io.File f = new java.io.File(inputs.get(0));
        String name = BamReaderAdapter.optString(opts, "name",
            f.getName().replaceFirst("\\.mzML$", ""));
        d.spectralStreams.put(name, MzMLReader.stream(f, name, StreamOpts.batchSpectra(opts), progress));
        return d;
    }
}
