/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.transport.TransferProgress;
import global.thalion.ttio.workbench.transport.WorkbenchTransportClient;

import org.java_websocket.WebSocket;
import org.java_websocket.drafts.Draft_6455;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.protocols.IProtocol;
import org.java_websocket.protocols.Protocol;
import org.java_websocket.server.WebSocketServer;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.RandomAccessFile;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link WorkbenchTransportClient#upload(String, String,
 * java.nio.file.Path, global.thalion.ttio.workbench.transport.ResumeState,
 * TransferProgress)} — the streaming-upload entry point added in
 * #130.
 *
 * <p>Uses an in-process {@link WebSocketServer} that speaks just
 * enough of the {@code ttio-transport} subprotocol to ack the
 * handshake, drain binary frames, count bytes, and emit
 * {@code done}. No daemon / no Python.</p>
 */
class WorkbenchTransportClientStreamingUploadTest {

    private TestUploadServer server;
    private int port;

    @BeforeEach
    void startServer() throws Exception {
        server = new TestUploadServer(new InetSocketAddress("127.0.0.1", 0));
        server.setReuseAddr(true);
        server.start();
        // WebSocketServer.start spawns a thread; the port isn't
        // guaranteed bound the instant start() returns. Poll briefly.
        long deadline = System.currentTimeMillis() + 5_000;
        while (server.getPort() <= 0 && System.currentTimeMillis() < deadline) {
            Thread.sleep(20);
        }
        port = server.getPort();
        assertTrue(port > 0, "test WS server failed to bind a port");
    }

    @AfterEach
    void stopServer() throws Exception {
        if (server != null) server.stop(1_000);
    }

    @Test
    void streamingUploadOfSmallTisFileCompletesAndReportsProgress(
            @TempDir Path dir) throws Exception {
        // ~10 MB synthetic payload — large enough to exercise multiple
        // chunkSize (64 KB) reads but cheap to write to a tmpfs/disk.
        Path tis = dir.resolve("sample.tis");
        int totalBytes = 10 * 1024 * 1024;
        byte[] block = new byte[64 * 1024];
        for (int i = 0; i < block.length; i++) block[i] = (byte) (i & 0xff);
        try (var os = Files.newOutputStream(tis)) {
            for (int i = 0; i < totalBytes / block.length; i++) os.write(block);
        }
        assertEquals(totalBytes, Files.size(tis));

        WorkbenchTransportClient client = WorkbenchTransportClient
            .builder("127.0.0.1", port)
            .token("test-token")
            .owner("alice")
            .defaultTimeoutMs(30_000L)
            .build();

        List<long[]> progressSamples = Collections.synchronizedList(new ArrayList<>());
        TransferProgress progress = (done, total) ->
            progressSamples.add(new long[]{done, total});

        WorkbenchTransportClient.UploadResult result = client.upload(
            "alpha", "uri:tio:test/streaming-small", tis, null, progress);

        assertEquals("uri:tio:test/streaming-small", result.containerUri());

        // Server received exactly totalBytes bytes.
        assertEquals(totalBytes, server.bytesReceived.get(),
            "server should have drained the entire payload");

        // Progress callback fired at least an initial (0, total) and
        // a final (total, total) sample.
        assertFalse(progressSamples.isEmpty(),
            "TransferProgress should have fired");
        long[] first = progressSamples.get(0);
        long[] last = progressSamples.get(progressSamples.size() - 1);
        assertEquals(0L, first[0], "first sample should be 0 bytes done");
        assertEquals(totalBytes, first[1],
            "first sample should report totalBytes as the total");
        assertEquals(totalBytes, last[0],
            "final sample should be totalBytes done");
        assertEquals(totalBytes, last[1],
            "final sample's total should be totalBytes");
    }

    /**
     * Drives a 100 MB sparse-file upload end-to-end through the
     * streaming overload and asserts the server drained the right
     * number of bytes. This catches a "streaming path silently
     * stops emitting after one chunk" regression.
     *
     * <p>The strict per-call read-size + chunked-coverage proofs
     * live in {@link global.thalion.ttio.workbench.transport
     * .FilePayloadSourceTest} which can reach the package-private
     * {@code FilePayloadSource} class directly. Together they pin
     * the bounded-heap contract: every call reads &le; {@code
     * chunkSize} bytes, and the whole file is delivered.</p>
     */
    @Test
    void streamingUploadOf100MbSparseFileCompletes(@TempDir Path dir)
            throws Exception {
        Path tis = dir.resolve("sparse-100mb.tis");
        long sparseSize = 100L * 1024 * 1024;  // 100 MB
        try (RandomAccessFile raf = new RandomAccessFile(tis.toFile(), "rw")) {
            raf.setLength(sparseSize);
        }
        assertEquals(sparseSize, Files.size(tis));

        WorkbenchTransportClient client = WorkbenchTransportClient
            .builder("127.0.0.1", port)
            .token("test-token")
            .owner("alice")
            .defaultTimeoutMs(120_000L)
            .build();

        AtomicLong lastBytesDone = new AtomicLong(0L);
        TransferProgress progress = (done, total) -> lastBytesDone.set(done);

        WorkbenchTransportClient.UploadResult result = client.upload(
            "alpha", "uri:tio:test/streaming-100mb", tis, null, progress);

        assertEquals("uri:tio:test/streaming-100mb", result.containerUri());
        assertEquals(sparseSize, server.bytesReceived.get(),
            "server should have drained the entire 100 MB payload");
        assertEquals(sparseSize, lastBytesDone.get(),
            "progress should have ticked all the way to the file size");
    }

    @Test
    void streamingUploadDeprecationCompatible_byteArrayPathStillWorks(
            @TempDir Path dir) throws Exception {
        // Confirms the legacy byte[] overload remains functional
        // after the PayloadSource refactor. Important: the byte[]
        // entry point is @Deprecated (commit 3) but MUST keep
        // working — test fixtures + Python/ObjC bridge callers
        // depend on it.
        byte[] payload = new byte[256 * 1024];
        for (int i = 0; i < payload.length; i++) payload[i] = (byte) (i & 0xff);

        WorkbenchTransportClient client = WorkbenchTransportClient
            .builder("127.0.0.1", port)
            .token("test-token")
            .owner("alice")
            .defaultTimeoutMs(30_000L)
            .build();

        WorkbenchTransportClient.UploadResult result = client.upload(
            "alpha", "uri:tio:test/legacy-bytes", payload);
        assertEquals("uri:tio:test/legacy-bytes", result.containerUri());
        assertEquals(payload.length, server.bytesReceived.get());
    }

    // ------------------------------------------------------------
    // In-process WS upload server stub
    // ------------------------------------------------------------

    /**
     * Minimal {@code ttio-transport} upload server:
     * <ol>
     *   <li>{@code onOpen}: notes the connection.</li>
     *   <li>{@code onMessage(String)}: parse the handshake JSON,
     *       reply with {@code {"type":"ack","handle":"stg-test"}}.</li>
     *   <li>{@code onMessage(ByteBuffer)}: tally bytes.</li>
     *   <li>When {@code onClose} fires OR the client signals
     *       end-of-upload (we use the byte count reaching the
     *       expected total — but we don't know the total here, so
     *       we simply respond {@code done} after every binary frame
     *       and the client ignores subsequent {@code done}s once
     *       its future has completed).</li>
     * </ol>
     *
     * <p>Test simplification: we emit {@code done} after the WS
     * peer's outbound channel falls quiet for ~50 ms. That's
     * coarse but enough to validate the byte-count drain.</p>
     */
    private static final class TestUploadServer extends WebSocketServer {

        final AtomicLong bytesReceived = new AtomicLong(0L);
        private volatile java.util.concurrent.ScheduledFuture<?> emitDoneTask;
        private final java.util.concurrent.ScheduledExecutorService scheduler =
            java.util.concurrent.Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "ttio-test-server-scheduler");
                t.setDaemon(true);
                return t;
            });

        TestUploadServer(InetSocketAddress addr) {
            super(addr, 4, draftsWithSubprotocol());
        }

        private static List<org.java_websocket.drafts.Draft> draftsWithSubprotocol() {
            List<IProtocol> protocols = List.of(new Protocol("ttio-transport"));
            return List.of(new Draft_6455(Collections.emptyList(), protocols));
        }

        @Override
        public void onOpen(WebSocket conn, ClientHandshake handshake) {}

        @Override
        public void onClose(WebSocket conn, int code, String reason, boolean remote) {}

        @Override
        public void onError(WebSocket conn, Exception ex) {}

        @Override
        public void onStart() {
            setConnectionLostTimeout(0);
        }

        @Override
        public void onMessage(WebSocket conn, String message) {
            // Treat any text frame as a handshake; reply with ack +
            // a fake stage handle. The real daemon's wire shape
            // emits {"type":"ack","handle":"stg-..."}.
            conn.send("{\"type\":\"ack\",\"handle\":\"stg-test-streaming\"}");
        }

        @Override
        public synchronized void onMessage(WebSocket conn, ByteBuffer bytes) {
            int n = bytes.remaining();
            bytesReceived.addAndGet(n);
            // Reschedule a "done" emission ~50ms after the last
            // binary frame. End-of-stream isn't framed at this layer
            // in the test; quiet-time triggers completion.
            if (emitDoneTask != null) emitDoneTask.cancel(false);
            emitDoneTask = scheduler.schedule(() -> {
                try {
                    // Don't echo container_uri — the driver's onMessage
                    // path falls back to the handshake-supplied value
                    // when the done frame omits it (see
                    // WorkbenchTransportClient.UploadDriver.onMessage,
                    // case DONE).
                    conn.send("{\"type\":\"done\","
                            + "\"bytes_received\":" + bytesReceived.get() + "}");
                } catch (Exception ignored) {}
            }, 100, TimeUnit.MILLISECONDS);
        }
    }
}
