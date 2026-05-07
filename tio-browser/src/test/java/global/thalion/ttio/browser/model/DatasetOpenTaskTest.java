package global.thalion.ttio.browser.model;

import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class DatasetOpenTaskTest {

    private static final Path FIXTURE = Paths.get(
        "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            // Toolkit already initialized (e.g. another test class started it)
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS), "JavaFX toolkit did not start");
    }

    @Test
    void openMinimalMsFixtureSucceedsAndPopulatesCounts() throws Exception {
        DatasetOpenTask task = new DatasetOpenTask(FIXTURE.toString(), true);
        ExecutorService exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(10, TimeUnit.SECONDS));
        try (OpenDataset result = task.get()) {
            assertNotNull(result);
            assertEquals(FIXTURE.toString(), result.path());
            assertTrue(result.readOnly());
            assertNotNull(result.dataset());
            assertEquals(1, result.msRunCount(), "minimal_ms.tio has 1 MS run");
            assertEquals(0, result.genomicRunCount());
            assertFalse(result.isEncrypted());
        }
    }

    @Test
    void openEncryptedFixtureSetsEncryptionBanner() throws Exception {
        Path enc = Paths.get(
            "../java/src/test/resources/ttio/encrypted.tio").toAbsolutePath();
        DatasetOpenTask task = new DatasetOpenTask(enc.toString(), true);
        ExecutorService exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(10, TimeUnit.SECONDS));
        try (OpenDataset result = task.get()) {
            assertTrue(result.isEncrypted());
            assertFalse(result.encryptionAlgorithm().isEmpty());
        }
    }
}
