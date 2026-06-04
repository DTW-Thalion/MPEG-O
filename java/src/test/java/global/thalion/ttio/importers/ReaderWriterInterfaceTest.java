package global.thalion.ttio.importers;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import global.thalion.ttio.io.ProgressSink;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.Writer;

class ReaderWriterInterfaceTest {
    static class OkReader implements Reader {
        public ImportedDataset read(List<String> inputs, Map<String, Object> opts,
                                    ProgressSink progress) { return new ImportedDataset(); }
    }
    static class OkWriter implements Writer {
        public void write(SpectralDataset ds, String layer, Path output,
                          Map<String, Object> opts) { }
    }
    @Test void readerImplementable() { assertTrue(new OkReader() instanceof Reader); }
    @Test void writerImplementable() { assertTrue(new OkWriter() instanceof Writer); }
}
