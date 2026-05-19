package global.thalion.ttio.browser.importers;

import java.util.List;
import java.util.Set;

import global.thalion.ttio.browser.diag.Diagnostics;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Verifies that BAM/SAM/CRAM/Thermo/MassLynx/Bruker import-format rows
 * grey out when their underlying binary probe reports unavailable, and
 * un-grey when it reports OK.
 *
 * <p>We can't reliably mock the {@link Diagnostics} static cache; instead
 * we observe the live cache and assert the contract the registry promises
 * (binaryAvailable matches isAvailable on the named probe).</p>
 */
class ImportFormatRegistryDiagnosticsTest {

    // v1.4.1 (PR #76): BAM/SAM/CRAM moved to the bundled htsjdk
    // library, so they are no longer binary-gated. The remaining
    // gated formats are vendor-specific binary parsers without a
    // pure-Java alternative.
    private static final Set<String> BINARY_GATED_FORMATS = Set.of(
        "Thermo .raw",
        "Waters MassLynx",
        "Bruker timsTOF"
    );

    @Test
    void binaryGatedFormatsCarryRequiredBinary() {
        for (ImportFormatSpec spec : ImportFormatRegistry.all()) {
            if (BINARY_GATED_FORMATS.contains(spec.name)) {
                assertNotNull(spec.requiredBinary,
                    "binary-gated format must declare requiredBinary: " + spec.name);
            } else {
                assertNull(spec.requiredBinary,
                    "non-gated format must not declare requiredBinary: " + spec.name);
            }
        }
    }

    @Test
    void bamSamCramHaveNoBinaryRequirement() {
        // Post-PR-#76 (htsjdk swap): the bundled SAM/BAM/CRAM reader
        // has no external binary dependency.
        for (String name : List.of("BAM", "SAM", "CRAM")) {
            ImportFormatSpec spec = lookup(name);
            assertNull(spec.requiredBinary,
                name + " must not declare a required binary "
                + "(post-PR-#76 htsjdk swap removed the samtools dep)");
        }
    }

    @Test
    void thermoRequiresThermoRawFileParser() {
        assertEquals("ThermoRawFileParser",
            lookup("Thermo .raw").requiredBinary);
    }

    @Test
    void watersRequiresMasslynxraw() {
        assertEquals("masslynxraw",
            lookup("Waters MassLynx").requiredBinary);
    }

    @Test
    void brukerRequiresPythonHelper() {
        assertEquals("Bruker Python helper",
            lookup("Bruker timsTOF").requiredBinary);
    }

    @Test
    void availabilityMirrorsDiagnosticsCache() {
        Diagnostics.probeAll();
        for (ImportFormatSpec spec : ImportFormatRegistry.all()) {
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
    void unavailableReasonMentionsRequiredBinary() {
        // Find a binary-gated spec whose binary is currently NOT available.
        Diagnostics.probeAll();
        for (ImportFormatSpec spec : ImportFormatRegistry.all()) {
            if (spec.requiredBinary != null
                    && !Diagnostics.isAvailable(spec.requiredBinary)
                    && spec.readerOnClasspath()) {
                String reason = spec.unavailableReason();
                assertNotNull(reason);
                assertTrue(reason.contains(spec.requiredBinary),
                    "unavailableReason must name the missing binary: " + reason);
                return;
            }
        }
        // If every binary happens to be present in this environment, the
        // contract still holds — we just can't observe it. That's fine.
    }

    @Test
    void availableExcludesGatedFormatsWhenBinaryMissing() {
        Diagnostics.probeAll();
        List<ImportFormatSpec> available = ImportFormatRegistry.available();
        for (ImportFormatSpec spec : ImportFormatRegistry.all()) {
            if (spec.requiredBinary != null
                    && !Diagnostics.isAvailable(spec.requiredBinary)) {
                assertFalse(available.contains(spec),
                    "available() must exclude gated formats when binary is missing: "
                    + spec.name);
            }
        }
    }

    private static ImportFormatSpec lookup(String name) {
        return ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst()
            .orElseThrow(() -> new AssertionError("no such format: " + name));
    }
}
