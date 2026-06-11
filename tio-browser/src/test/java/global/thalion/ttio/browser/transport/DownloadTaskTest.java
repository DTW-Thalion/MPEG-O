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
        // Run the task on a DAEMON worker so a hung/slow DownloadTask can
        // never keep this forked surefire JVM alive (the previous
        // newSingleThreadExecutor() worker was non-daemon, which is how a
        // failed run could hang CI for 6h). On timeout we additionally
        // shutdownNow() to interrupt the task and then still assert.
        var exec = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "DownloadTaskTest-worker");
            t.setDaemon(true);
            return t;
        });
        try {
            exec.submit(task);
            exec.shutdown();
            // 90s, not 60s: the underlying TransportClient.fetchPackets has
            // two SEQUENTIAL 30s internal timeouts (connectBlocking + the
            // EndOfStream collect), so a slow-but-eventually-failing run can
            // legitimately occupy ~60s inside call(). A 60s executor bound
            // raced with that and produced an opaque "did not finish" flake.
            // With 90s the client's own timeout surfaces the real cause via
            // task.get() instead; if it still overruns we interrupt so the
            // JVM can never hang (the actual CI-killer was the leaked
            // non-daemon thread, fixed in TransportClient + below).
            if (!exec.awaitTermination(90, TimeUnit.SECONDS)) {
                exec.shutdownNow();           // interrupt the stuck task
                exec.awaitTermination(10, TimeUnit.SECONDS);
                fail("DownloadTask did not finish within 90s");
            }
        } finally {
            // Belt-and-suspenders: ensure the worker is never left running.
            exec.shutdownNow();
        }
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

    @Test
    void emitsProgressReportsDuringDownload(@TempDir Path tmp) throws Exception {
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
            java.util.List<global.thalion.ttio.browser.progress.ProgressReport> got =
                new java.util.concurrent.CopyOnWriteArrayList<>();
            task.setProgressListener(got::add);

            runAndWait(task);

            try {
                task.get();
            } catch (ExecutionException ee) {
                fail("DownloadTask failed: " + ee.getCause(), ee.getCause());
            }

            assertFalse(got.isEmpty(),
                "task should emit at least one ProgressReport");
            assertTrue(got.stream().anyMatch(r -> r.unitsDone() >= 1),
                "task should emit a terminal report with unitsDone >= 1");
        } finally {
            server.stop();
        }
    }

    @Test
    void emitsMultipleMidStreamProgressReports(@TempDir Path tmp) throws Exception {
        Path fixture = Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
            .toAbsolutePath();
        assertTrue(Files.exists(fixture), "fixture missing: " + fixture);

        int port = findFreePort();
        TransportServer server = new TransportServer(
            fixture.toString(), "127.0.0.1", port);
        server.start();

        try {
            Path out = tmp.resolve("midstream.tio");
            DownloadTask task = new DownloadTask(
                "ws://127.0.0.1:" + port + "/",
                Map.of(),
                out.toString(),
                "hdf5",
                30);
            java.util.List<global.thalion.ttio.browser.progress.ProgressReport> got =
                new java.util.concurrent.CopyOnWriteArrayList<>();
            task.setProgressListener(got::add);

            runAndWait(task);

            try {
                task.get();
            } catch (ExecutionException ee) {
                fail("DownloadTask (mid-stream) failed: " + ee.getCause(), ee.getCause());
            }

            assertFalse(got.isEmpty(), "task should emit at least one ProgressReport");

            // Verify bytesDone is monotonically non-decreasing across all reports.
            long monotonic = -1L;
            boolean sawMid = false;
            long finalBytes = got.get(got.size() - 1).bytesDone();
            for (var r : got) {
                assertTrue(r.bytesDone() >= monotonic,
                    "bytesDone must be monotonically non-decreasing, got " +
                    r.bytesDone() + " after " + monotonic);
                monotonic = r.bytesDone();
                if (r.bytesDone() > 0 && r.bytesDone() < finalBytes) sawMid = true;
            }
            // A tiny fixture might fit in a single binary frame (one packet =
            // one mid-stream report that also equals finalBytes). Guard to match
            // UploadTaskTest conventions.
            if (finalBytes > 0) {
                assertTrue(sawMid,
                    "expected at least one mid-stream report with 0 < bytesDone < finalBytes=" +
                    finalBytes + "; reports=" + got.size());
            }
        } finally {
            server.stop();
        }
    }
}