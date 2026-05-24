package global.thalion.ttio.browser.transport;

import com.sun.net.httpserver.HttpServer;
import javafx.application.Platform;
import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Tests for {@link UploadTask} scheme dispatch and error handling.
 */
class UploadTaskTest {

    private static final Path FIXTURE =
        Paths.get("../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS), "JavaFX toolkit did not start");
    }

    private static int findFreePort() throws Exception {
        try (ServerSocket s = new ServerSocket(0)) { return s.getLocalPort(); }
    }

    private void runAndWait(UploadTask task) throws InterruptedException {
        var exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(60, TimeUnit.SECONDS),
            "UploadTask did not finish within 60s");
    }

    @Test
    void badSchemeThrowsIllegalArgumentException() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);
        UploadTask task = new UploadTask(FIXTURE.toString(), "ftp://localhost/x", "", false);
        runAndWait(task);
        try {
            task.get();
            fail("Expected ExecutionException wrapping IllegalArgumentException");
        } catch (ExecutionException ex) {
            assertInstanceOf(IllegalArgumentException.class, ex.getCause(),
                "Cause should be IllegalArgumentException, got: " + ex.getCause());
        }
    }

    @Test
    void httpSchemeUploadsSuccessfully() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);

        int port = findFreePort();
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        srv.createContext("/up", exchange -> {
            exchange.getRequestBody().readAllBytes();
            exchange.sendResponseHeaders(200, 0);
            exchange.close();
        });
        srv.start();

        try {
            UploadTask task = new UploadTask(
                FIXTURE.toString(),
                "http://127.0.0.1:" + port + "/up",
                "tok", false);
            runAndWait(task);
            task.get(); // throws if the task failed
        } finally {
            srv.stop(0);
        }
    }

    @Test
    void wsSchemeUploadsSuccessfully() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);

        int port = findFreePort();
        CountDownLatch serverReady = new CountDownLatch(1);
        CountDownLatch uploadDone  = new CountDownLatch(1);

        WebSocketServer wsServer = new WebSocketServer(
                new InetSocketAddress("127.0.0.1", port)) {
            @Override public void onStart() { serverReady.countDown(); }
            @Override public void onOpen(WebSocket c, ClientHandshake h) {}
            @Override public void onMessage(WebSocket c, String m) {
                if (m.contains("end")) uploadDone.countDown();
            }
            @Override public void onMessage(WebSocket c, ByteBuffer b) {}
            @Override public void onClose(WebSocket c, int code, String r, boolean rem) {}
            @Override public void onError(WebSocket c, Exception ex) {}
        };
        wsServer.setReuseAddr(true);
        wsServer.start();
        assertTrue(serverReady.await(5, TimeUnit.SECONDS), "WS server did not start");

        try {
            UploadTask task = new UploadTask(
                FIXTURE.toString(),
                "ws://127.0.0.1:" + port + "/",
                "", false);
            runAndWait(task);
            task.get();
            assertTrue(uploadDone.await(5, TimeUnit.SECONDS),
                "Server did not receive end frame");
        } finally {
            wsServer.stop(200);
        }
    }

    @Test
    void httpsSchemeDispatchesToHttpUploader() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);
        // HTTPS with no server -> IOException (not IllegalArgumentException)
        UploadTask task = new UploadTask(
            FIXTURE.toString(), "https://127.0.0.1:19999/no-server", "", false);
        runAndWait(task);
        try {
            task.get();
            fail("Expected an exception (no server)");
        } catch (ExecutionException ex) {
            assertFalse(ex.getCause() instanceof IllegalArgumentException,
                "Should not get IllegalArgumentException for https scheme");
        }
    }

    @Test
    void emitsProgressReportsDuringUpload() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);

        int port = findFreePort();
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        srv.createContext("/up", exchange -> {
            exchange.getRequestBody().readAllBytes();
            exchange.sendResponseHeaders(200, 0);
            exchange.close();
        });
        srv.start();

        try {
            UploadTask task = new UploadTask(
                FIXTURE.toString(),
                "http://127.0.0.1:" + port + "/up",
                "", false);
            java.util.List<global.thalion.ttio.browser.progress.ProgressReport> got =
                new java.util.concurrent.CopyOnWriteArrayList<>();
            task.setProgressListener(got::add);
            runAndWait(task);
            task.get(); // throws if it failed
            assertFalse(got.isEmpty(),
                "task should emit at least one ProgressReport");
            var last = got.get(got.size() - 1);
            assertTrue(last.bytesDone() > 0L || last.unitsDone() > 0L,
                "terminal report should show non-zero progress");
            assertTrue(last.bytesTotal() > 0L,
                "byte total should be known for a file-source upload");
        } finally {
            srv.stop(0);
        }
    }
}
