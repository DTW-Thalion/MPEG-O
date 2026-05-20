/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import com.sun.net.httpserver.HttpServer;
import global.thalion.ttio.workbench.federation.FederationClient;
import org.junit.jupiter.api.Test;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * W6.5 -- federation client. Mirrors the Python {@code test_federation}.
 * The key contract: a v1.0 single-node server (no
 * {@code /v1/federation/peers}, HTTP 404) yields an empty peer list,
 * not an error. Exercised against a local {@link HttpServer} stub.
 */
class FederationClientTest {

    /** Start a one-shot stub that answers /v1/federation/peers with the
     *  given status + JSON body; returns the bound port. */
    private static HttpServer stub(int status, String body) throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/v1/federation/peers", exchange -> {
            byte[] resp = body.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(status, resp.length == 0 ? -1 : resp.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(resp);
            }
        });
        server.start();
        return server;
    }

    private static FederationClient clientFor(HttpServer server) {
        int port = server.getAddress().getPort();
        return new FederationClient("127.0.0.1", port, "http", "t");
    }

    @Test
    void v1Server404YieldsEmptyList() throws Exception {
        HttpServer server = stub(404, "{\"error\":\"not found\"}");
        try {
            FederationClient client = clientFor(server);
            assertEquals(List.of(), client.peers());
            assertFalse(client.isFederated());
        } finally {
            server.stop(0);
        }
    }

    @Test
    void parsesPeers() throws Exception {
        HttpServer server = stub(200,
            "{\"peers\":["
            + "{\"peer_id\":\"node-a\",\"url\":\"wss://a.example:8443\",\"status\":\"online\"},"
            + "{\"id\":\"node-b\",\"url\":\"wss://b.example:8443\"}"
            + "]}");
        try {
            List<FederationClient.Peer> peers = clientFor(server).peers();
            assertEquals(2, peers.size());
            assertEquals(new FederationClient.Peer(
                "node-a", "wss://a.example:8443", "online"), peers.get(0));
            assertEquals(new FederationClient.Peer(
                "node-b", "wss://b.example:8443", "unknown"), peers.get(1));
        } finally {
            server.stop(0);
        }
    }

    @Test
    void emptyPeersIsNotFederated() throws Exception {
        HttpServer server = stub(200, "{\"peers\":[]}");
        try {
            FederationClient client = clientFor(server);
            assertTrue(client.peers().isEmpty());
            assertFalse(client.isFederated());
        } finally {
            server.stop(0);
        }
    }

    @Test
    void otherErrorThrows() throws Exception {
        HttpServer server = stub(500, "{\"error\":\"boom\"}");
        try {
            assertThrows(WorkbenchHttp.WorkbenchHttpException.class,
                () -> clientFor(server).peers());
        } finally {
            server.stop(0);
        }
    }
}
