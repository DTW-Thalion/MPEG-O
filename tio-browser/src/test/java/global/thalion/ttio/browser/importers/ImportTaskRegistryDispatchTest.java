package global.thalion.ttio.browser.importers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.progress.ProgressReport;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * GT3: verifies {@link ImportTask} dispatches the registry-covered formats
 * through the SDK {@code ImporterRegistry}/{@code ImportedDataset} path
 * (rather than the deleted per-format {@code importX} bodies), while
 * preserving the two-phase progress UX (reader 0..50%, writer 50..100%).
 */
class ImportTaskRegistryDispatchTest {

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
    void mzMLDispatchesViaRegistryAndReopens(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
            .toAbsolutePath();
        Path target = tmp.resolve("registry.tio");
        ImportTask task = new ImportTask(specByName("mzML"),
            ImportConfig.basic(src, target, "hdf5", "run_0001", "registry dispatch"));
        runAndWait(task);
        try {
            task.get();
        } catch (ExecutionException ee) {
            fail("mzML registry dispatch threw: " + ee.getCause(), ee.getCause());
        }
        assertTrue(Files.exists(target),
            "expected " + target + " after registry-dispatched import");
        try (SpectralDataset ds = SpectralDataset.open(target.toString())) {
            assertFalse(ds.msRuns().isEmpty(),
                "registry-dispatched mzML should yield at least one MS run");
        }
    }

    @Test
    void mzMLDispatchPreservesTwoPhaseProgress(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
            .toAbsolutePath();
        Path target = tmp.resolve("phases.tio");
        ImportTask task = new ImportTask(specByName("mzML"),
            ImportConfig.basic(src, target, "hdf5", "run_0001", "phase test"));
        var got = new java.util.concurrent.CopyOnWriteArrayList<ProgressReport>();
        task.setProgressListener(got::add);
        runAndWait(task);
        try {
            task.get();
        } catch (ExecutionException ee) {
            fail("mzML registry dispatch threw: " + ee.getCause(), ee.getCause());
        }
        assertFalse(got.isEmpty(), "should emit progress reports");
        // The unified bar (PhaseProgress) maps the reader phase onto
        // 0..50% and the writer phase onto 50..100% via the bytes domain,
        // so ProgressReport.percent() reflects the unified position.
        // Confirm both halves are exercised: at least one sample in the
        // 0..50% reader half, at least one in the 50..100% writer half,
        // and the final sample reaches 100%.
        double maxFrac = got.stream()
            .mapToDouble(ProgressReport::percent)
            .filter(d -> !Double.isNaN(d))
            .max().orElse(0.0);
        assertTrue(maxFrac >= 0.999,
            "two-phase progress should terminate at 100%, got max " + maxFrac);
        boolean sawReaderHalf = got.stream()
            .anyMatch(r -> r.percent() > 0.0 && r.percent() <= 0.5 + 1e-6);
        assertTrue(sawReaderHalf,
            "reader phase should emit a sample in the 0..50% half");
        boolean sawWriterHalf = got.stream()
            .anyMatch(r -> r.percent() > 0.5 + 1e-6 && r.percent() <= 1.0 + 1e-6);
        assertTrue(sawWriterHalf,
            "writer phase should emit a sample in the 50..100% half");
    }
}
