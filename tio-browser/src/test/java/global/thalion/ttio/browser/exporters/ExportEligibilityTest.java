package global.thalion.ttio.browser.exporters;

import java.nio.file.Path;
import java.nio.file.Paths;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.OpenDataset;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ExportEligibilityTest {

    private static final Path FULL_MS =
        Paths.get("../java/src/test/resources/ttio/full_ms.tio").toAbsolutePath();
    private static final Path NMR_1D =
        Paths.get("../java/src/test/resources/ttio/nmr_1d.tio").toAbsolutePath();

    private static ExportFormatSpec specByName(String name) {
        return ExportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst().orElseThrow();
    }

    private static OpenDataset openRO(Path p) {
        SpectralDataset ds = SpectralDataset.open(p.toString());
        return new OpenDataset(p.toString(), true, ds);
    }

    @Test
    void mzmlEligibleOnFullMsDataset() {
        try (OpenDataset d = openRO(FULL_MS)) {
            assertTrue(ExportEligibility.check(specByName("mzML (indexed)"), d),
                "mzML should be eligible for full_ms.tio");
        }
    }

    @Test
    void nmrmlIneligibleOnFullMsDatasetWithReason() {
        try (OpenDataset d = openRO(FULL_MS)) {
            ExportFormatSpec spec = specByName("nmrML");
            assertFalse(ExportEligibility.check(spec, d),
                "nmrML should NOT be eligible for full_ms.tio (no NMR runs)");
            assertEquals("No NMR runs in this file.",
                ExportEligibility.tooltipReason(spec, d));
        }
    }

    @Test
    void nmrmlEligibleOnNmrDataset() {
        try (OpenDataset d = openRO(NMR_1D)) {
            assertTrue(ExportEligibility.check(specByName("nmrML"), d),
                "nmrML should be eligible for nmr_1d.tio");
        }
    }

    @Test
    void genomicFormatsIneligibleOnAnalyticalDataset() {
        try (OpenDataset d = openRO(FULL_MS)) {
            assertFalse(ExportEligibility.check(specByName("BAM"), d));
            assertFalse(ExportEligibility.check(specByName("CRAM"), d));
            assertFalse(ExportEligibility.check(specByName("FASTQ"), d));
            assertEquals("No genomic runs in this file.",
                ExportEligibility.tooltipReason(specByName("BAM"), d));
        }
    }

    @Test
    void referencesIneligibleOnDatasetWithoutReferences() {
        try (OpenDataset d = openRO(FULL_MS)) {
            ExportFormatSpec spec = specByName("FASTA (reference)");
            assertFalse(ExportEligibility.check(spec, d));
            assertEquals("No embedded references in this file.",
                ExportEligibility.tooltipReason(spec, d));
        }
    }

    @Test
    void isaAlwaysEligible() {
        try (OpenDataset d = openRO(FULL_MS)) {
            assertTrue(ExportEligibility.check(specByName("ISA-Tab/JSON"), d));
        }
    }

    @Test
    void msImageIneligibleOnNonImagingDataset() {
        try (OpenDataset d = openRO(FULL_MS)) {
            ExportFormatSpec spec = specByName("imzML");
            assertFalse(ExportEligibility.check(spec, d));
            assertEquals("No MSImage runs in this file.",
                ExportEligibility.tooltipReason(spec, d));
        }
    }

    @Test
    void tooltipReasonReturnsDescriptionWhenEligible() {
        try (OpenDataset d = openRO(FULL_MS)) {
            ExportFormatSpec spec = specByName("mzML (indexed)");
            assertEquals(spec.description,
                ExportEligibility.tooltipReason(spec, d));
        }
    }
}
