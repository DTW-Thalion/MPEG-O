package global.thalion.ttio.importers;

import static org.junit.jupiter.api.Assertions.*;
import java.lang.reflect.Method;
import org.junit.jupiter.api.Test;

class BrukerReaderDatasetTest {
    @Test
    void readDatasetExistsAndReturnsImportedDataset() throws Exception {
        Method m = null;
        for (Method c : BrukerTDFReader.class.getMethods())
            if (c.getName().equals("readDataset")) { m = c; break; }
        assertNotNull(m, "readDataset must exist");
        assertEquals(ImportedDataset.class, m.getReturnType());
    }

    @Test
    void draftWithDelegateRoutesWriteThroughTheDelegate(@org.junit.jupiter.api.io.TempDir java.nio.file.Path tmp) throws Exception {
        // A delegate-backed draft must call the delegate (not SpectralDataset.create) on write().
        java.nio.file.Path target = tmp.resolve("out.tio");
        ImportedDataset draft = ImportedDataset.delegated((output, progress) -> {
            java.nio.file.Files.writeString(output, "sentinel");
            return output;
        });
        java.nio.file.Path returned = draft.write(target);
        assertEquals(target, returned);
        assertEquals("sentinel", java.nio.file.Files.readString(target));
    }
}
