package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;

import global.thalion.ttio.browser.exporters.ExportFormatRegistry;
import global.thalion.ttio.browser.exporters.ExportFormatSpec;
import global.thalion.ttio.browser.importers.ImportFormatRegistry;
import global.thalion.ttio.browser.importers.ImportFormatSpec;
import global.thalion.ttio.exporters.ExporterRegistry;
import global.thalion.ttio.importers.ImporterRegistry;

/** GT2: registry-covered GUI rows source {@code fileExts} + {@code requiredBinary}
 *  from the TTI-O SDK registries (single source of truth). GUI-local rows
 *  (fasta/fastq) keep their hardcoded metadata. */
final class RegistryDelegationTest {

    private static ImportFormatSpec importSpec(String name) {
        return ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name)).findFirst().orElseThrow();
    }

    private static ExportFormatSpec exportSpec(String name) {
        return ExportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name)).findFirst().orElseThrow();
    }

    @Test
    void importMzMlDelegatesToSdk() {
        ImportFormatSpec gui = importSpec("mzML");
        var sdk = ImporterRegistry.specFor("mzml");
        assertEquals(sdk.extensions(), gui.fileExts);
        assertEquals(sdk.requiredTool(), gui.requiredBinary);
        assertNull(gui.requiredBinary);
    }

    @Test
    void importThermoRawDelegatesToSdk() {
        ImportFormatSpec gui = importSpec("Thermo .raw");
        var sdk = ImporterRegistry.specFor("thermo-raw");
        assertEquals(sdk.extensions(), gui.fileExts);
        assertEquals(sdk.requiredTool(), gui.requiredBinary);
        assertEquals("ThermoRawFileParser", gui.requiredBinary);
    }

    @Test
    void importBamDelegatesToSdkWithNullBinary() {
        ImportFormatSpec gui = importSpec("BAM");
        var sdk = ImporterRegistry.specFor("bam");
        assertEquals(sdk.extensions(), gui.fileExts);
        assertEquals(sdk.requiredTool(), gui.requiredBinary);
        // htsjdk-backed: no external samtools required.
        assertNull(gui.requiredBinary);
    }

    @Test
    void exportBamDelegatesToSdkWithNullBinary() {
        ExportFormatSpec gui = exportSpec("BAM");
        var sdk = ExporterRegistry.specFor("bam");
        assertEquals(sdk.extensions(), gui.fileExts);
        assertEquals(sdk.requiredTool(), gui.requiredBinary);
        assertNull(gui.requiredBinary);
    }

    @Test
    void guiLocalFastaImportRowNotDelegated() {
        // FASTA is GUI-local (not in the SDK encode registry); keeps its
        // hardcoded extension list and null binary.
        assertNull(SdkFormatKeys.importKey("FASTA"));
        ImportFormatSpec gui = importSpec("FASTA");
        assertNotNull(gui.fileExts);
        assertNull(gui.requiredBinary);
    }
}
