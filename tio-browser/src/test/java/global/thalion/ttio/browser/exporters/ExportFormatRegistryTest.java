package global.thalion.ttio.browser.exporters;

import java.util.List;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ExportFormatRegistryTest {

    @Test
    void registryDiscoversElevenRows() {
        List<ExportFormatSpec> all = ExportFormatRegistry.all();
        assertEquals(11, all.size(),
            "expected 11 export-format rows; found " + all.size());
    }

    @Test
    void allWritersOnClasspathInDevelopment() {
        List<ExportFormatSpec> all = ExportFormatRegistry.all();
        List<String> missing = all.stream()
            .filter(s -> !s.writerOnClasspath())
            .map(s -> s.writerClassFqn)
            .toList();
        assertTrue(missing.isEmpty(),
            "missing writer classes (ttio jar likely incomplete): " + missing);
    }

    @Test
    void availableEqualsAllWhenAllWritersResolve() {
        assertEquals(ExportFormatRegistry.all().size(),
            ExportFormatRegistry.available().size());
    }

    @Test
    void descriptionsLoadedForAllFormats() {
        for (ExportFormatSpec spec : ExportFormatRegistry.all()) {
            assertNotEquals("(no description)", spec.description,
                "missing description for format: " + spec.name);
            assertFalse(spec.description.isBlank(),
                "blank description for format: " + spec.name);
        }
    }

    @Test
    void formatNamesAreUnique() {
        long distinct = ExportFormatRegistry.all().stream()
            .map(s -> s.name).distinct().count();
        assertEquals(ExportFormatRegistry.all().size(), distinct,
            "duplicate export format name in registry");
    }

    @Test
    void containsExpectedFormats() {
        List<String> names = ExportFormatRegistry.all().stream()
            .map(s -> s.name).toList();
        assertTrue(names.contains("mzML (indexed)"),     "mzML row missing: " + names);
        assertTrue(names.contains("mzTab"),              "mzTab row missing: " + names);
        assertTrue(names.contains("imzML"),              "imzML row missing: " + names);
        assertTrue(names.contains("nmrML"),              "nmrML row missing: " + names);
        assertTrue(names.contains("JCAMP-DX"),           "JCAMP-DX row missing: " + names);
        assertTrue(names.contains("ISA-Tab/JSON"),       "ISA row missing: " + names);
        assertTrue(names.contains("BAM"),                "BAM row missing: " + names);
        assertTrue(names.contains("CRAM"),               "CRAM row missing: " + names);
        assertTrue(names.contains("FASTA (reference)"),  "FASTA-ref row missing: " + names);
        assertTrue(names.contains("FASTA (reads)"),      "FASTA-reads row missing: " + names);
        assertTrue(names.contains("FASTQ"),              "FASTQ row missing: " + names);
    }
}
