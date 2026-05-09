package global.thalion.ttio.browser.exporters;

import java.util.List;
import java.util.Set;

import global.thalion.ttio.browser.diag.Diagnostics;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Mirrors {@code ImportFormatRegistryDiagnosticsTest}: verifies that
 * BAM/CRAM export rows depend on samtools, that other formats are
 * not gated by a binary, and that {@link ExportFormatRegistry#available()}
 * filters gated rows when the binary is absent.
 */
class ExportFormatRegistryDiagnosticsTest {

    private static final Set<String> BINARY_GATED_FORMATS = Set.of("BAM", "CRAM");

    @Test
    void binaryGatedFormatsCarryRequiredBinary() {
        for (ExportFormatSpec spec : ExportFormatRegistry.all()) {
            if (BINARY_GATED_FORMATS.contains(spec.name)) {
                assertNotNull(spec.requiredBinary,
                    "binary-gated export format must declare requiredBinary: "
                    + spec.name);
            } else {
                assertNull(spec.requiredBinary,
                    "non-gated export format must not declare requiredBinary: "
                    + spec.name);
            }
        }
    }

    @Test
    void bamCramRequireSamtools() {
        for (String name : List.of("BAM", "CRAM")) {
            ExportFormatSpec spec = lookup(name);
            assertEquals("samtools", spec.requiredBinary,
                name + " must depend on samtools");
        }
    }

    @Test
    void availabilityMirrorsDiagnosticsCache() {
        Diagnostics.probeAll();
        for (ExportFormatSpec spec : ExportFormatRegistry.all()) {
            if (spec.requiredBinary == null) {
                assertTrue(spec.binaryAvailable(),
                    "no-binary spec must always report binaryAvailable=true: "
                    + spec.name);
            } else {
                assertEquals(
                    Diagnostics.isAvailable(spec.requiredBinary),
                    spec.binaryAvailable(),
                    "binaryAvailable must mirror Diagnostics.isAvailable: "
                    + spec.name);
            }
        }
    }

    @Test
    void availableExcludesGatedFormatsWhenBinaryMissing() {
        Diagnostics.probeAll();
        List<ExportFormatSpec> available = ExportFormatRegistry.available();
        for (ExportFormatSpec spec : ExportFormatRegistry.all()) {
            if (spec.requiredBinary != null
                    && !Diagnostics.isAvailable(spec.requiredBinary)) {
                assertFalse(available.contains(spec),
                    "available() must exclude gated export formats when "
                    + "binary is missing: " + spec.name);
            }
        }
    }

    private static ExportFormatSpec lookup(String name) {
        return ExportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst()
            .orElseThrow(() -> new AssertionError("no such format: " + name));
    }
}
