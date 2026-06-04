/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers.readers;

import global.thalion.ttio.importers.BrukerTDFReader;
import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.Reader;
import global.thalion.ttio.io.ProgressSink;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/** {@link Reader} adapter for Bruker timsTOF {@code .d} directories.
 *  Mirrors the GUI {@code ImportTask.importBrukerTimsTOF}: validates the
 *  directory's SQLite metadata up front, then returns the write-through
 *  draft from {@link BrukerTDFReader#readDataset(Path)} (the {@code .tio}
 *  is produced by the Python helper at write time).
 *
 *  <p>The Python {@code ms2} opt has no effect on the Java write-through
 *  path: {@code BrukerTDFReader.readDataset} takes no {@code ms2}
 *  argument (the Python CLI helper decides frame selection), so the opt
 *  is accepted but ignored here.</p> */
public final class BrukerReaderAdapter implements Reader {
    @Override
    public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                ProgressSink progress) throws IOException {
        return BrukerTDFReader.readDataset(Path.of(inputs.get(0)));
    }
}
