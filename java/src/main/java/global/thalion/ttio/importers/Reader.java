package global.thalion.ttio.importers;

import global.thalion.ttio.io.ProgressSink;
import java.io.IOException;
import java.util.List;
import java.util.Map;

/** Uniform importer interface: parse one or more sources into an
 *  {@link ImportedDataset}. A reader does NOT write any {@code .tio} file
 *  (the registry / caller calls {@code ImportedDataset.write()}).
 *
 *  <p>{@code inputs.get(0)} is the primary source; extra entries carry
 *  secondary files (e.g. imzML {@code .ibd}). {@code opts} carries
 *  format-specific knobs (e.g. {@code name}, {@code sample}, {@code region},
 *  {@code reference}, {@code ms2}, {@code ibd}, {@code encoding}).
 *
 *  <p>Cross-language equivalents: Python {@code ttio.importers.base.Reader},
 *  Objective-C {@code TTIOReader}.
 */
public interface Reader {
    ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                         ProgressSink progress) throws IOException;
}
