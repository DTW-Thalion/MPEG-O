package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class SdkFormatKeysTest {
    @Test void importKeysMap() {
        assertEquals("mzml", SdkFormatKeys.importKey("mzML"));
        assertEquals("bruker-timstof", SdkFormatKeys.importKey("Bruker timsTOF"));
        assertEquals("thermo-raw", SdkFormatKeys.importKey("Thermo .raw"));
        assertEquals("bam", SdkFormatKeys.importKey("BAM"));
        assertNull(SdkFormatKeys.importKey("FASTA"));   // GUI-local
        assertNull(SdkFormatKeys.importKey("FASTQ"));
    }
    @Test void exportKeysMap() {
        assertEquals("mzml", SdkFormatKeys.exportKey("mzML (indexed)"));
        assertEquals("isa", SdkFormatKeys.exportKey("ISA-Tab/JSON"));
        assertEquals("imzml", SdkFormatKeys.exportKey("imzML"));
        assertEquals("cram", SdkFormatKeys.exportKey("CRAM"));
        assertNull(SdkFormatKeys.exportKey("FASTA (reference)"));
        assertNull(SdkFormatKeys.exportKey("FASTA (reads)"));
        assertNull(SdkFormatKeys.exportKey("FASTQ"));
    }
    @Test void everyRegistryKeyIsReachable() {
        // every SDK key must be the value of exactly one GUI display-name mapping
        for (String k : global.thalion.ttio.importers.ImporterRegistry.registryKeys())
            assertTrue(SdkFormatKeys.IMPORT.containsValue(k), "import key unmapped: " + k);
        for (String k : global.thalion.ttio.exporters.ExporterRegistry.registryKeys())
            assertTrue(SdkFormatKeys.EXPORT.containsValue(k), "export key unmapped: " + k);
    }
}
