package global.thalion.ttio.browser.importers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import global.thalion.ttio.SpectralDataset;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class ImportTaskTest {

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

    private ImportFormatSpec specByName(String name) {
        return ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst().orElseThrow();
    }

    private void runAndWait(ImportTask task) throws InterruptedException {
        var exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(60, TimeUnit.SECONDS),
            "ImportTask did not finish within 60s");
    }

    @Test
    void importsMzMLFixtureProducesValidTio(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
            .toAbsolutePath();
        Path target = tmp.resolve("out.tio");
        ImportTask task = new ImportTask(specByName("mzML"),
            ImportConfig.basic(src, target, "hdf5", "run_0001", "tiny pwiz"));
        runAndWait(task);
        try {
            task.get();
        } catch (ExecutionException ee) {
            fail("mzML import threw: " + ee.getCause(), ee.getCause());
        }
        assertTrue(Files.exists(target),
            "expected " + target + " to exist after import");
        try (SpectralDataset ds = SpectralDataset.open(target.toString())) {
            assertFalse(ds.msRuns().isEmpty(),
                "imported mzML should yield at least one MS run");
        }
    }

    @Test
    void importsNmrMLFixtureProducesNmrRun(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/bmse000325.nmrML")
            .toAbsolutePath();
        Path target = tmp.resolve("nmr.tio");
        ImportTask task = new ImportTask(specByName("nmrML"),
            ImportConfig.basic(src, target, "hdf5", "nmr_0001", "bmse000325"));
        runAndWait(task);
        try {
            task.get();
        } catch (ExecutionException ee) {
            fail("nmrML import threw: " + ee.getCause(), ee.getCause());
        }
        assertTrue(Files.exists(target));
        try (SpectralDataset ds = SpectralDataset.open(target.toString())) {
            assertFalse(ds.msRuns().isEmpty(),
                "nmrML import yields a run in the analytical-runs map");
        }
    }

    @Test
    void unsupportedFormatRaisesClearError(@TempDir Path tmp) throws Exception {
        Path src = tmp.resolve("dummy.imzML");
        Path target = tmp.resolve("out.tio");
        ImportTask task = new ImportTask(
            specByName("imzML"),
            ImportConfig.basic(src, target, "hdf5", "img_0001", ""));
        runAndWait(task);
        ExecutionException ee = assertThrows(ExecutionException.class,
            task::get);
        assertTrue(ee.getCause() instanceof UnsupportedOperationException,
            "wrong cause: " + ee.getCause());
        assertTrue(ee.getCause().getMessage().contains("not yet wired"),
            "missing 'not yet wired' in: " + ee.getCause().getMessage());
    }
}
