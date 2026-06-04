package global.thalion.ttio.exporters;

import global.thalion.ttio.SpectralDataset;
import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;

/** Uniform exporter interface: serialize one layer of an <em>opened</em>
 *  {@link SpectralDataset} to {@code output}. The registry / caller owns
 *  opening the {@code .tio} and selecting the run.
 *
 *  <p>Cross-language equivalents: Python {@code ttio.exporters.base.Writer},
 *  Objective-C {@code TTIOWriter}.
 */
public interface Writer {
    void write(SpectralDataset ds, String layer, Path output,
               Map<String, Object> opts) throws IOException;
}
