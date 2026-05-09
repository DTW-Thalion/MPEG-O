package global.thalion.ttio.browser.transport;

import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration tests for {@link TisWsUploader} against an embedded WebSocket server.
 */
class TisWsUploaderTest {

    private CollectingWsServer wsServer;
    private int port;

    private static int findFreePort() throws Exception {
        try (ServerSocket s = new ServerSocket(0)) { return s.getLocalPort(); }
    }

    @BeforeEach
    void startServer() throws Exception {
        port = findFreePort();
        wsServer = new CollectingWsServer(port);
        wsServer.start();
        assertTrue(wsServer.serverStarted.await(5, TimeUnit.SECONDS),
            "WS server did not start");
    }

    @AfterEach
    void stopServer() throws Exception {
        if (wsServer != null) wsServer.stop(200);
    }

    @Test
    void uploadSendsCorrectFrameSequence(@TempDir Path tmp) throws Exception {
        byte[] payload = "FAKE-TIS-DATA-123456".getBytes();
        Path tis = tmp.resolve("upload.tis");
        Files.write(tis, payload);

        TisWsUploader.upload(
            URI.create("ws://127.0.0.1:" + port + "/"),
            tis, "sample.tio");

        assertTrue(wsServer.done.await(10, TimeUnit.SECONDS),
            "Server should receive all frames");

        List<Object> frames = wsServer.frames;
        assertTrue(frames.size() >= 3,
            "Should have at least 3 frames (lead + data + trail)");

        // First frame: leading text envelope
        assertTrue(frames.get(0) instanceof String, "First frame should be text");
        String first = (String) frames.get(0);
        assertTrue(first.contains("\"type\"") && first.contains("upload"),
            "First text frame should contain type:upload, got: " + first);
        assertTrue(first.contains("\"filename\"") && first.contains("sample.tio"),
            "First text frame should contain filename, got: " + first);

        // Last frame: trailing text envelope
        Object last = frames.get(frames.size() - 1);
        assertTrue(last instanceof String, "Last frame should be text");
        String lastStr = (String) last;
        assertTrue(lastStr.contains("\"type\"") && lastStr.contains("end"),
            "Last text frame should contain type:end, got: " + lastStr);

        // Middle frames: binary — concatenated bytes equal payload
        int totalBinary = 0;
        List<byte[]> chunks = new ArrayList<>();
        for (int i = 1; i < frames.size() - 1; i++) {
            assertTrue(frames.get(i) instanceof byte[],
                "Middle frame " + i + " should be binary");
            byte[] chunk = (byte[]) frames.get(i);
            chunks.add(chunk);
            totalBinary += chunk.length;
        }
        byte[] reassembled = new byte[totalBinary];
        int off = 0;
        for (byte[] chunk : chunks) {
            System.arraycopy(chunk, 0, reassembled, off, chunk.length);
            off += chunk.length;
        }
        assertArrayEquals(payload, reassembled,
            "Binary frames should be byte-equal to .tis content");
    }

    @Test
    void uploadWithLargeFile(@TempDir Path tmp) throws Exception {
        // ~200 KiB to exercise chunked upload (> 64 KiB CHUNK_SIZE)
        byte[] payload = new byte[200 * 1024];
        for (int i = 0; i < payload.length; i++) payload[i] = (byte) (i & 0xFF);
        Path tis = tmp.resolve("large.tis");
        Files.write(tis, payload);

        TisWsUploader.upload(
            URI.create("ws://127.0.0.1:" + port + "/"),
            tis, "large.tio");

        assertTrue(wsServer.done.await(15, TimeUnit.SECONDS));

        int totalBinary = 0;
        List<byte[]> chunks = new ArrayList<>();
        List<Object> frames = wsServer.frames;
        for (int i = 1; i < frames.size() - 1; i++) {
            byte[] chunk = (byte[]) frames.get(i);
            chunks.add(chunk);
            totalBinary += chunk.length;
        }
        assertEquals(payload.length, totalBinary);
        byte[] reassembled = new byte[totalBinary];
        int off = 0;
        for (byte[] chunk : chunks) {
            System.arraycopy(chunk, 0, reassembled, off, chunk.length);
            off += chunk.length;
        }
        assertArrayEquals(payload, reassembled);
    }

    // ---------------------------------------------------------- embedded WS server

    private static final class CollectingWsServer extends WebSocketServer {
        final List<Object>      frames        = Collections.synchronizedList(new ArrayList<>());
        final CountDownLatch    serverStarted = new CountDownLatch(1);
        final CountDownLatch    done          = new CountDownLatch(1);

        CollectingWsServer(int port) {
            super(new InetSocketAddress("127.0.0.1", port));
            setReuseAddr(true);
        }

        @Override public void onStart() { serverStarted.countDown(); }
        @Override public void onOpen(WebSocket conn, ClientHandshake h) {}

        @Override
        public void onMessage(WebSocket conn, String message) {
            frames.add(message);
            if (message.contains("end")) done.countDown();
        }

        @Override
        public void onMessage(WebSocket conn, ByteBuffer bytes) {
            byte[] raw = new byte[bytes.remaining()];
            bytes.get(raw);
            frames.add(raw);
        }

        @Override public void onClose(WebSocket conn, int code, String r, boolean rem) {}
        @Override public void onError(WebSocket conn, Exception ex) {}
    }
}
