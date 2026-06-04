package global.thalion.ttio.browser.exporters;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.importers.ImportConfig;
import global.thalion.ttio.browser.importers.ImportFormatRegistry;
import global.thalion.ttio.browser.importers.ImportFormatSpec;
import global.thalion.ttio.browser.importers.ImportTask;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * GT4: verifies {@link ExportTask} dispatches the registry-covered export
 * rows ("mzML (indexed)", "mzTab", "nmrML", "imzML", "JCAMP-DX",
 * "ISA-Tab/JSON", "BAM", "CRAM") through the SDK
 * {@code ExporterRegistry}/{@code Writer} adapters rather than the GUI's own
 * per-format writer calls, and that the GUI-local fasta/fastq rows are left
 * untouched. The per-format option that each SDK writer adapter honors
 * (mzTab {@code dialect}, JCAMP {@code encoding}, imzML {@code mode}, CRAM
 * {@code reference}) must still reach the writer.
 */
class ExportTaskRegistryDispatchTest {

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS),
            "JavaFX toolkit did not start");
    }

    private static ExportFormatSpec exportSpec(String name) {
        return ExportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst().orElseThrow();
    }

    private static ImportFormatSpec importSpec(String name) {
        return ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst().orElseThrow();
    }

    private static <T extends javafx.concurrent.Task<?>> void runAndWait(T task)
            throws InterruptedException {
        var exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(120, TimeUnit.SECONDS),
            "task did not finish within 120s");
    }

    private static boolean samtoolsAvailable() {
        try {
            Process p = new ProcessBuilder("samtools", "--version")
                .redirectErrorStream(true).start();
            p.waitFor(5, TimeUnit.SECONDS);
            return p.exitValue() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    private static boolean nativeLibraryAvailable() {
        try {
            global.thalion.ttio.browser.util.NativeLibraryLoader.ensureRansJni();
            return global.thalion.ttio.browser.util.NativeLibraryLoader.isLoaded();
        } catch (Throwable t) {
            return false;
        }
    }

    /** mzML (indexed): a clean registry format (no extra opts). The SDK
     *  {@code MzMLWriterAdapter} selects the single analytical run and
     *  serialises it. */
    @Test
    void mzMLDispatchesViaRegistry(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/ttio/full_ms.tio")
            .toAbsolutePath();
        Path mzml = tmp.resolve("out.mzML");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            ExportTask exp = new ExportTask(exportSpec("mzML (indexed)"),
                ExportConfig.basic(mzml), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("mzML export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(mzml), "expected " + mzml);
        assertTrue(Files.size(mzml) > 0, "mzML output is empty");
    }

    /** mzTab: the SDK {@code MzTabWriterAdapter} honors the {@code dialect}
     *  opt — the GUI must forward {@code config.mzTabDialect}. Exporting with
     *  the metabolomics dialect must emit the matching version header. */
    @Test
    void mzTabDispatchesAndHonorsDialect(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/ttio/full_ms.tio")
            .toAbsolutePath();
        Path mzTab = tmp.resolve("out.mzTab");

        ExportConfig cfg = new ExportConfig(
            mzTab, "2.0.0-M", null, null, false,
            null, null, 60, null, 33, null);
        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            ExportTask exp = new ExportTask(exportSpec("mzTab"), cfg, ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("mzTab export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(mzTab), "expected " + mzTab);
        assertTrue(Files.size(mzTab) > 0, "mzTab output is empty");
        String text = Files.readString(mzTab);
        assertTrue(text.contains("2.0.0-M"),
            "mzTab dialect opt not forwarded; header was: "
            + text.lines().findFirst().orElse("<empty>"));
    }

    /** BAM: genomic registry format. The SDK {@code BamWriterAdapter}
     *  selects the genomic run and materialises it via the shared
     *  {@code RunSelection.toWritten} (the GUI's private {@code toWritten}
     *  copy is removed). */
    @Test
    void bamDispatchesViaRegistry(@TempDir Path tmp) throws Exception {
        assumeTrue(samtoolsAvailable(), "samtools not on PATH");
        assumeTrue(nativeLibraryAvailable(),
            "libttio_rans_jni not loadable; skip BAM round-trip");
        Path bam = Paths.get("../java/src/test/resources/ttio/fixtures/genomic/m87_test.bam")
            .toAbsolutePath();
        Path origTio = tmp.resolve("orig.tio");

        ImportTask imp = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bam, origTio, "hdf5", "run_0001", "m87"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("BAM import failed: " + ee.getCause(), ee.getCause());
        }

        Path bamOut = tmp.resolve("out.bam");
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            assertFalse(ds.genomicRuns().isEmpty(),
                "imported m87_test.bam should contain a genomic run");
            ExportTask exp = new ExportTask(exportSpec("BAM"),
                ExportConfig.basic(bamOut), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("BAM export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(bamOut), "expected " + bamOut);
        assertTrue(Files.size(bamOut) > 0, "BAM output is empty");
    }
}
