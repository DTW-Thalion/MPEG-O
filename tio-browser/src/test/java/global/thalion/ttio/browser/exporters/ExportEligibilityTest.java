package global.thalion.ttio.browser.exporters;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;
import org.junit.jupiter.api.io.TempDir;
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

    @Test
    void imzmlEligibleOnImageBearingDataset(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("img.tio");
        int w = 2, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        double[] mz = { 100.0, 200.0, 300.0, 400.0 };
        MSImage img = new MSImage(w, h, sp, 0, 1.0, 1.0, "raster",
            cube, mz, "", "",
            List.of(), List.of(), List.of());
        try (Hdf5File f = Hdf5File.create(tio.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        try (OpenDataset d = openRO(tio)) {
            assertTrue(ExportEligibility.check(specByName("imzML"), d),
                "imzML should be eligible on dataset with /study/image_cube");
        }
    }
}
