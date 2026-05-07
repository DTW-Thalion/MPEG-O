package global.thalion.ttio.browser.exporters;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
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

class ExportTaskTest {

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

    /** True iff libttio_rans_jni resolves via {@code java.library.path}.
     *  BAM round-trip needs the NAME_TOKENIZED_V2 codec which has no
     *  pure-Java fallback in v1.0+. */
    private static boolean nativeLibraryAvailable() {
        try {
            global.thalion.ttio.browser.util.NativeLibraryLoader.ensureRansJni();
            return global.thalion.ttio.browser.util.NativeLibraryLoader.isLoaded();
        } catch (Throwable t) {
            return false;
        }
    }

    @Test
    void mzMLRoundTrip(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
            .toAbsolutePath();
        Path mzml = tmp.resolve("out.mzML");
        Path reTio = tmp.resolve("re.tio");
        Path origTio = tmp.resolve("orig.tio");

        // import source mzML -> orig.tio
        ImportTask imp = new ImportTask(importSpec("mzML"),
            ImportConfig.basic(src, origTio, "hdf5", "run_0001", "tiny pwiz"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("import failed: " + ee.getCause(), ee.getCause());
        }

        // export orig.tio -> mzml
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            ExportTask exp = new ExportTask(exportSpec("mzML (indexed)"),
                ExportConfig.basic(mzml), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(mzml));

        // re-import mzml -> re.tio
        ImportTask imp2 = new ImportTask(importSpec("mzML"),
            ImportConfig.basic(mzml, reTio, "hdf5", "run_0001", "round-trip"));
        runAndWait(imp2);
        try { imp2.get(); } catch (ExecutionException ee) {
            fail("re-import failed: " + ee.getCause(), ee.getCause());
        }

        try (SpectralDataset orig = SpectralDataset.open(origTio.toString());
             SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            assertEquals(orig.msRuns().size(), round.msRuns().size());
            AcquisitionRun ro = orig.msRuns().values().iterator().next();
            AcquisitionRun rr = round.msRuns().values().iterator().next();
            assertEquals(ro.spectra().size(), rr.spectra().size());
            // Spot-check intensity arrays of first MS spectrum.
            MassSpectrum mso = (MassSpectrum) ro.spectra().get(0);
            MassSpectrum msr = (MassSpectrum) rr.spectra().get(0);
            assertArrayEquals(mso.intensityValues(), msr.intensityValues(), 1e-9,
                "first-spectrum intensity mismatch after mzML round-trip");
        }
    }

    @Test
    void fastqRoundTripFromBamFixture(@TempDir Path tmp) throws Exception {
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

        Path fastq = tmp.resolve("out.fastq");
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            assertFalse(ds.genomicRuns().isEmpty(),
                "imported m87_test.bam should contain a genomic run");
            ExportTask exp = new ExportTask(exportSpec("FASTQ"),
                ExportConfig.basic(fastq), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("FASTQ export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(fastq), "expected " + fastq);
        assertTrue(Files.size(fastq) > 0, "FASTQ output is empty");
        // Sanity: starts with '@' (FASTQ record header).
        byte[] first = Files.readAllBytes(fastq);
        assertEquals('@', (char) first[0],
            "FASTQ output should begin with '@' header line");
    }

    @Test
    void bamRoundTripPreservesReadCount(@TempDir Path tmp) throws Exception {
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
        int origReadCount;
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            origReadCount = ds.genomicRuns().values().iterator().next().readCount();
            ExportTask exp = new ExportTask(exportSpec("BAM"),
                ExportConfig.basic(bamOut), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("BAM export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(bamOut));
        Path reTio = tmp.resolve("re.tio");
        ImportTask imp2 = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bamOut, reTio, "hdf5", "run_0001", "round"));
        runAndWait(imp2);
        try { imp2.get(); } catch (ExecutionException ee) {
            fail("BAM re-import failed: " + ee.getCause(), ee.getCause());
        }
        try (SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            int roundReadCount = round.genomicRuns().values().iterator().next().readCount();
            assertEquals(origReadCount, roundReadCount,
                "BAM round-trip should preserve read count");
        }
    }

    @Test
    void unsupportedImzMLRaisesClearError(@TempDir Path tmp) throws Exception {
        // Empty dataset is enough — eligibility wouldn't pass in the
        // dialog, but the task itself must surface a clear error if
        // dispatched directly (defensive).
        Path src = Paths.get("../java/src/test/resources/ttio/full_ms.tio")
            .toAbsolutePath();
        Path out = tmp.resolve("out.imzML");
        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            ExportTask exp = new ExportTask(exportSpec("imzML"),
                ExportConfig.basic(out), ds);
            runAndWait(exp);
            ExecutionException ee = assertThrows(ExecutionException.class,
                exp::get);
            assertTrue(ee.getCause() instanceof UnsupportedOperationException,
                "wrong cause: " + ee.getCause());
            assertTrue(ee.getCause().getMessage().contains("not yet wired"),
                "missing 'not yet wired' in: " + ee.getCause().getMessage());
        }
    }
}
