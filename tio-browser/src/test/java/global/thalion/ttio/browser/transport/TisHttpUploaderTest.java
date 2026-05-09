package global.thalion.ttio.browser.transport;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration tests for {@link TisHttpUploader} against an embedded HTTP server.
 */
class TisHttpUploaderTest {

    private HttpServer server;
    private int port;
    private final List<byte[]> bodies      = new CopyOnWriteArrayList<>();
    private final List<String> authHeaders = new CopyOnWriteArrayList<>();

    private static int findFreePort() throws Exception {
        try (ServerSocket s = new ServerSocket(0)) { return s.getLocalPort(); }
    }

    @BeforeEach
    void startServer() throws Exception {
        port = findFreePort();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        server.createContext("/upload", exchange -> {
            authHeaders.add(exchange.getRequestHeaders().getFirst("Authorization"));
            bodies.add(exchange.getRequestBody().readAllBytes());
            exchange.sendResponseHeaders(200, 0);
            exchange.close();
        });
        server.start();
    }

    @AfterEach
    void stopServer() { if (server != null) server.stop(0); }

    @Test
    void putSendsBodyByteEqual(@TempDir Path tmp) throws Exception {
        byte[] payload = "FAKE-TIS-CONTENT".getBytes();
        Path tis = tmp.resolve("test.tis");
        Files.write(tis, payload);

        TisHttpUploader.upload(
            URI.create("http://127.0.0.1:" + port + "/upload"), tis, null);

        assertEquals(1, bodies.size(), "should receive exactly one PUT body");
        assertArrayEquals(payload, bodies.get(0), "PUT body should be byte-equal");
    }

    @Test
    void putIncludesBearerTokenWhenProvided(@TempDir Path tmp) throws Exception {
        Path tis = tmp.resolve("token.tis");
        Files.write(tis, "DATA".getBytes());

        TisHttpUploader.upload(
            URI.create("http://127.0.0.1:" + port + "/upload"), tis, "my-secret-token");

        assertEquals(1, authHeaders.size());
        assertEquals("Bearer my-secret-token", authHeaders.get(0));
    }

    @Test
    void putOmitsAuthHeaderWhenTokenBlank(@TempDir Path tmp) throws Exception {
        Path tis = tmp.resolve("notoken.tis");
        Files.write(tis, "PAYLOAD".getBytes());

        TisHttpUploader.upload(
            URI.create("http://127.0.0.1:" + port + "/upload"), tis, "");

        assertEquals(1, authHeaders.size());
        assertNull(authHeaders.get(0),
            "Authorization header should be absent for blank token");
    }

    @Test
    void nonSuccessStatusThrowsIOException(@TempDir Path tmp) throws Exception {
        int errPort = findFreePort();
        HttpServer errServer = HttpServer.create(
            new InetSocketAddress("127.0.0.1", errPort), 0);
        errServer.createContext("/fail", exchange -> {
            exchange.sendResponseHeaders(500, 0); exchange.close();
        });
        errServer.start();
        try {
            Path tis = tmp.resolve("fail.tis");
            Files.write(tis, "X".getBytes());
            assertThrows(java.io.IOException.class,
                () -> TisHttpUploader.upload(
                    URI.create("http://127.0.0.1:" + errPort + "/fail"), tis, null));
        } finally {
            errServer.stop(0);
        }
    }
}
