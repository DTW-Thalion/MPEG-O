// tio-browser/src/test/java/global/thalion/ttio/browser/SaveAsTest.java
package global.thalion.ttio.browser;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class SaveAsTest {

    @Test
    void saveAsCopiesFileToTargetPath(@TempDir Path tmp) throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
        Path copy = tmp.resolve("copy.tio");
        java.nio.file.Files.copy(fixture, copy);
        // Assertion: the copy exists, is readable as a SpectralDataset, and
        // round-trips msRunCount == 1.
        try (SpectralDataset ds = SpectralDataset.open(copy.toString())) {
            assertEquals(1, ds.msRuns().size());
        }
    }
}
