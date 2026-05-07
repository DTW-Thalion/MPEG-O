package global.thalion.ttio.browser.importers;

import java.util.List;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ImportFormatRegistryTest {

    @Test
    void registryDiscoversThirteenRows() {
        List<ImportFormatSpec> all = ImportFormatRegistry.all();
        assertEquals(13, all.size(),
            "expected 13 format rows; found " + all.size());
    }

    @Test
    void allReadersOnClasspathInDevelopment() {
        List<ImportFormatSpec> all = ImportFormatRegistry.all();
        List<String> missing = all.stream()
            .filter(s -> !s.readerOnClasspath())
            .map(s -> s.readerClassFqn)
            .toList();
        assertTrue(missing.isEmpty(),
            "missing reader classes (ttio jar likely incomplete): " + missing);
    }

    @Test
    void availableEqualsAllWhenAllReadersResolve() {
        assertEquals(ImportFormatRegistry.all().size(),
            ImportFormatRegistry.available().size());
    }

    @Test
    void descriptionsLoadedForAllFormats() {
        for (ImportFormatSpec spec : ImportFormatRegistry.all()) {
            assertNotEquals("(no description)", spec.description,
                "missing description for format: " + spec.name);
            assertFalse(spec.description.isBlank(),
                "blank description for format: " + spec.name);
        }
    }

    @Test
    void formatNamesAreUnique() {
        long distinct = ImportFormatRegistry.all().stream()
            .map(s -> s.name).distinct().count();
        assertEquals(ImportFormatRegistry.all().size(), distinct,
            "duplicate format name in registry");
    }
}
