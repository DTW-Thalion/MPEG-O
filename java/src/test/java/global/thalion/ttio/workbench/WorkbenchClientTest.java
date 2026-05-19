/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.auth.BearerAuth;
import global.thalion.ttio.workbench.auth.OIDCAuth;
import global.thalion.ttio.workbench.auth.PasswordTotpAuth;
import global.thalion.ttio.workbench.auth.Session;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the W2 Java SDK foundation: WorkbenchClient
 * factory + auth providers + URL parser. Mirrors the Python
 * {@code tests/workbench/test_client.py} suite -- both languages
 * cover the same shape so cross-language drift is caught.
 */
class WorkbenchClientTest {

    // ---------------- URL parser

    @Test
    void parseUrlWss() {
        WorkbenchClient.Endpoint e = WorkbenchClient.parseUrl(
            "wss://biobank.example.com:8443/transport");
        assertEquals("biobank.example.com", e.host());
        assertEquals(8443, e.port());
        assertEquals("wss", e.wsScheme());
        assertEquals("https", e.httpScheme());
    }

    @Test
    void parseUrlWsDefaultPort() {
        WorkbenchClient.Endpoint e = WorkbenchClient.parseUrl(
            "ws://localhost/transport");
        assertEquals("localhost", e.host());
        assertEquals(8443, e.port());  // workbench-server default
        assertEquals("ws", e.wsScheme());
        assertEquals("http", e.httpScheme());
    }

    @Test
    void parseUrlHttps() {
        WorkbenchClient.Endpoint e = WorkbenchClient.parseUrl(
            "https://workbench.internal:8443");
        assertEquals("wss", e.wsScheme());
        assertEquals("https", e.httpScheme());
    }

    @Test
    void parseUrlBareHostPort() {
        WorkbenchClient.Endpoint e = WorkbenchClient.parseUrl("localhost:8443");
        assertEquals("localhost", e.host());
        assertEquals(8443, e.port());
        assertEquals("ws", e.wsScheme());
    }

    @Test
    void parseUrlRejectsUnknownScheme() {
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> WorkbenchClient.parseUrl("gopher://x"));
        assertTrue(ex.getMessage().contains("unsupported scheme"));
    }

    @Test
    void parseUrlRejectsMissingHost() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchClient.parseUrl("wss:///"));
    }

    // ---------------- auth providers

    @Test
    void passwordTotpAuthHoldsUsername() {
        PasswordTotpAuth a = new PasswordTotpAuth("alice", "pw", "012345");
        assertEquals("alice", a.username());
    }

    @Test
    void passwordTotpAuthRejectsMissingFields() {
        assertThrows(IllegalArgumentException.class,
            () -> new PasswordTotpAuth("", "pw", "012345"));
        assertThrows(IllegalArgumentException.class,
            () -> new PasswordTotpAuth("alice", null, "012345"));
        assertThrows(IllegalArgumentException.class,
            () -> new PasswordTotpAuth("alice", "pw", ""));
    }

    @Test
    void bearerAuthSynthesisesSession() {
        BearerAuth a = new BearerAuth(
            "ttiowbs_" + "x".repeat(43),
            "alice",
            List.of("alpha"),
            Set.of("containers.read.any_project"),
            2_000_000_000L);
        Session s = a.authenticate("h", 8443, "https");
        assertTrue(s.token().startsWith("ttiowbs_"));
        assertEquals("alice", s.username());
        assertEquals(List.of("alpha"), s.projects());
        assertEquals("bearer", s.provider());
    }

    @Test
    void bearerAuthMinimalCtor() {
        BearerAuth a = new BearerAuth(
            "ttiowbs_" + "x".repeat(43), "alice");
        Session s = a.authenticate("h", 8443, "https");
        assertEquals("alice", s.username());
        assertTrue(s.projects().isEmpty());
        assertTrue(s.capabilities().isEmpty());
    }

    @Test
    void bearerAuthRejectsBadToken() {
        assertThrows(IllegalArgumentException.class,
            () -> new BearerAuth("wrong_prefix", "alice"));
    }

    @Test
    void bearerAuthRejectsEmptyUsername() {
        assertThrows(IllegalArgumentException.class,
            () -> new BearerAuth("ttiowbs_" + "x".repeat(43), ""));
    }

    @Test
    void oidcAuthRaisesNotImplemented() {
        // Construction is cheap; the v1.1 deferral fires on call.
        OIDCAuth a = new OIDCAuth("https://idp.example.com", "client");
        assertEquals("https://idp.example.com", a.issuer());
        assertEquals("client", a.clientId());
        assertThrows(UnsupportedOperationException.class, a::username);
        assertThrows(UnsupportedOperationException.class,
            () -> a.authenticate("h", 8443, "https"));
    }

    @Test
    void oidcAuthDefaultCtor() {
        OIDCAuth a = new OIDCAuth();
        assertNull(a.issuer());
        assertNull(a.clientId());
        assertThrows(UnsupportedOperationException.class, a::username);
    }

    // ---------------- connect() factory

    @Test
    void connectRequiresAuth() {
        IllegalArgumentException ex = assertThrows(
            IllegalArgumentException.class,
            () -> WorkbenchClient.connect("wss://localhost:8443/transport", null));
        assertTrue(ex.getMessage().contains("auth"));
    }

    @Test
    void connectCallsProviderAuthenticate() {
        StubAuth auth = new StubAuth();
        WorkbenchClient client = WorkbenchClient.connect(
            "wss://biobank.example.com:8443/transport", auth);
        assertEquals("biobank.example.com", auth.lastHost);
        assertEquals(8443, auth.lastPort);
        assertEquals("https", auth.lastScheme);  // https sibling of wss
        assertNotNull(client.session());
        assertEquals("alice", client.session().username());
        assertEquals("biobank.example.com", client.host());
        assertEquals("wss", client.wsScheme());
    }

    @Test
    void reauthRefreshesSession() {
        StubAuth auth = new StubAuth();
        WorkbenchClient client = WorkbenchClient.connect(
            "ws://localhost:8443", auth);
        Session first = client.session();
        client.reauth();
        Session second = client.session();
        // StubAuth returns a NEW Session each call -- they should
        // be different instances even with identical contents.
        assertNotSame(first, second);
    }

    @Test
    void closeIsNoop() {
        // v1.0 contract: close() doesn't talk to the server. Make
        // sure double-close doesn't throw.
        WorkbenchClient client = WorkbenchClient.connect(
            "ws://localhost:8443", new StubAuth());
        client.close();
        client.close();  // no-op on re-close
    }

    // ---------------- W3 + W4 surfaces (live)

    @Test
    void w3AndW4SubClientsAreLive() {
        // W3 promoted client.pipelines / jobs; W4 promoted
        // sessions / sessionProxy. All four sub-client factories
        // are now live -- constructing them is pure (no network).
        // Actually calling list()/submit()/terminate() would hit
        // the network -- out of scope for this unit test.
        WorkbenchClient client = WorkbenchClient.connect(
            "ws://localhost:8443", new StubAuth());
        assertNotNull(client.pipelines());
        assertNotNull(client.jobs());
        assertNotNull(client.sessions());
        // sessionProxy builder is pure (no WS open until run()).
        assertNotNull(client.sessionProxy("01HSESS", "/"));
    }

    // ---------------- test stub

    private static final class StubAuth implements AuthProvider {
        String lastHost;
        int    lastPort;
        String lastScheme;

        @Override
        public String username() { return "alice"; }

        @Override
        public Session authenticate(String host, int port, String scheme) {
            lastHost = host;
            lastPort = port;
            lastScheme = scheme;
            return new Session(
                "ttiowbs_" + "x".repeat(43),
                "alice",
                "01HXYUSR",
                Set.of(),
                List.of(),
                2_000_000_000L,
                "stub",
                "01HXYSES");
        }
    }
}
