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
    void availableContainsOnlyFullyAvailableFormats() {
        // Phase 12.2: available() now filters by both reader-on-classpath
        // AND requiredBinary availability. Every spec returned by
        // available() must satisfy fullyAvailable().
        for (ImportFormatSpec spec : ImportFormatRegistry.available()) {
            assertTrue(spec.fullyAvailable(),
                "available() must only include fully-available formats: "
                + spec.name);
        }
        // Every non-binary-gated format must always be available, since
        // their reader classes resolve in development.
        for (ImportFormatSpec spec : ImportFormatRegistry.all()) {
            if (spec.requiredBinary == null) {
                assertTrue(ImportFormatRegistry.available().contains(spec),
                    "non-gated format must always be in available(): "
                    + spec.name);
            }
        }
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
