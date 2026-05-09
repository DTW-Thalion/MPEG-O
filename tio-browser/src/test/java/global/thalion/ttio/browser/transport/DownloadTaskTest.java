package global.thalion.ttio.browser.transport;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.TransportServer;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * End-to-end tests for {@link DownloadTask} against a live
 * {@link TransportServer} backed by {@code minimal_ms.tio}.
 */
class DownloadTaskTest {

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            // Already started
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS),
            "JavaFX toolkit did not start");
    }

    private static int findFreePort() throws Exception {
        try (ServerSocket s = new ServerSocket(0)) {
            return s.getLocalPort();
        }
    }

    private void runAndWait(DownloadTask task) throws InterruptedException {
        var exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(60, TimeUnit.SECONDS),
            "DownloadTask did not finish within 60s");
    }

    @Test
    void downloadFromLocalServerProducesByteEqualMsRuns(@TempDir Path tmp) throws Exception {
        Path fixture = Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
            .toAbsolutePath();
        assertTrue(Files.exists(fixture), "fixture missing: " + fixture);

        int port = findFreePort();
        TransportServer server = new TransportServer(
            fixture.toString(), "127.0.0.1", port);
        server.start();

        try {
            Path out = tmp.resolve("downloaded.tio");
            DownloadTask task = new DownloadTask(
                "ws://127.0.0.1:" + port + "/",
                Map.of(),
                out.toString(),
                "hdf5",
                30);

            runAndWait(task);

            try {
                task.get();
            } catch (ExecutionException ee) {
                fail("DownloadTask failed: " + ee.getCause(), ee.getCause());
            }

            assertTrue(Files.exists(out), "downloaded .tio should exist");
            assertEquals(out.toString(), task.get(), "task value should be output path");

            try (SpectralDataset orig = SpectralDataset.open(fixture.toString());
                 SpectralDataset got  = SpectralDataset.open(out.toString())) {

                assertEquals(orig.msRuns().size(), got.msRuns().size(),
                    "MS run count mismatch after Transport round-trip");

                var origRun = orig.msRuns().values().iterator().next();
                var gotRun  = got.msRuns().values().iterator().next();

                assertEquals(origRun.spectrumCount(), gotRun.spectrumCount(),
                    "spectrum count mismatch");
            }
        } finally {
            server.stop();
        }
    }

    @Test
    void downloadWithNonEmptyFilterForwardsCorrectly(@TempDir Path tmp) throws Exception {
        Path fixture = Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
            .toAbsolutePath();
        assertTrue(Files.exists(fixture), "fixture missing: " + fixture);

        int port = findFreePort();
        TransportServer server = new TransportServer(
            fixture.toString(), "127.0.0.1", port);
        server.start();

        try {
            Path out = tmp.resolve("filtered.tio");
            // ms_level=1 filter - server will only stream MS1 spectra
            DownloadTask task = new DownloadTask(
                "ws://127.0.0.1:" + port + "/",
                Map.of("ms_level", 1),
                out.toString(),
                "hdf5",
                30);

            runAndWait(task);

            try {
                task.get();
            } catch (ExecutionException ee) {
                fail("DownloadTask with filter failed: " + ee.getCause(), ee.getCause());
            }

            assertTrue(Files.exists(out), "filtered .tio should exist");

            try (SpectralDataset got = SpectralDataset.open(out.toString())) {
                assertFalse(got.msRuns().isEmpty(), "filtered download should have at least one run");
            }
        } finally {
            server.stop();
        }
    }

    @Test
    void timeoutSecondsReturnedCorrectly() {
        DownloadTask task = new DownloadTask(
            "ws://localhost:9000/",
            Map.of(),
            "/tmp/test.tio",
            "hdf5",
            42);
        assertEquals(42, task.timeoutSeconds());
    }
}