/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.sessions.BindMountValidator;
import global.thalion.ttio.workbench.sessions.Session;
import global.thalion.ttio.workbench.sessions.SessionProxy;
import global.thalion.ttio.workbench.sessions.SessionsClient;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for W4 sessions: Session record, BindMountValidator,
 * SessionProxy attach builder + URL constructor.
 *
 * <p>Cross-language anchor test pins the attach handshake JSON
 * against the same literal the Python suite asserts on.</p>
 */
class SessionsTest {

    // ---------------- Session record

    @Test
    void sessionFromJsonMinimalStarting() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("session_id",        "01HSESS");
        body.put("status",            "starting");
        body.put("project",           "alpha");
        body.put("owner",             "alice");
        body.put("engine_identifier", "shell");
        body.put("started_at",        1_700_000_000L);
        Session s = Session.fromJson(body);
        assertEquals("01HSESS", s.sessionId());
        assertEquals("starting", s.status());
        assertNull(s.hostPort());
        assertFalse(s.isTerminal());
        assertFalse(s.isAttachable());
    }

    @Test
    void sessionFromJsonRunningHasRuntimeFields() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("session_id",        "01HSESS");
        body.put("status",            "running");
        body.put("project",           "alpha");
        body.put("owner",             "alice");
        body.put("engine_identifier", "shell");
        body.put("started_at",        1_700_000_000L);
        body.put("host_port",         18443);
        body.put("pid",               12345);
        body.put("container_id",      "shell-12345");
        body.put("working_dir",       "/tmp/work");
        body.put("ready_at",          1_700_000_005L);
        body.put("last_seen_at",      1_700_000_300L);
        body.put("command",           List.of("bash", "-l"));
        body.put("env",               Map.of("X", "y"));
        body.put("bind_mounts",       Map.of("/data", "/data"));
        Session s = Session.fromJson(body);
        assertTrue(s.isAttachable());
        assertFalse(s.isTerminal());
        assertEquals(18443, s.hostPort());
        assertEquals(12345, s.pid());
        assertEquals(List.of("bash", "-l"), s.command());
    }

    @Test
    void terminalStatuses() {
        for (String status : new String[]{"terminated", "failed"}) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("session_id", "01H"); body.put("status", status);
            body.put("project", "p");      body.put("owner", "u");
            body.put("engine_identifier", "shell");
            body.put("started_at", 0L);
            assertTrue(Session.fromJson(body).isTerminal(),
                "expected terminal: " + status);
        }
    }

    @Test
    void nonTerminalStatuses() {
        for (String status : new String[]{"starting", "running", "terminating"}) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("session_id", "01H"); body.put("status", status);
            body.put("project", "p");      body.put("owner", "u");
            body.put("engine_identifier", "shell");
            body.put("started_at", 0L);
            assertFalse(Session.fromJson(body).isTerminal(),
                "expected non-terminal: " + status);
        }
    }

    @Test
    void onlyRunningIsAttachable() {
        for (String status : Session.ALL_STATUSES) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("session_id", "01H"); body.put("status", status);
            body.put("project", "p");      body.put("owner", "u");
            body.put("engine_identifier", "shell");
            body.put("started_at", 0L);
            assertEquals("running".equals(status),
                Session.fromJson(body).isAttachable(),
                "unexpected attachable for " + status);
        }
    }

    // ---------------- BindMountValidator

    @Test
    void bindMountsHappyPath() {
        BindMountValidator.validate(
            Map.of("/var/lib/tti-workbench/containers/alpha/data", "/data"),
            "alpha",
            "/var/lib/tti-workbench/containers");
    }

    @Test
    void bindMountsRejectsRelativeHost() {
        assertThrows(IllegalArgumentException.class,
            () -> BindMountValidator.validate(
                Map.of("data", "/data"), "alpha", null));
    }

    @Test
    void bindMountsRejectsTraversal() {
        assertThrows(IllegalArgumentException.class,
            () -> BindMountValidator.validate(
                Map.of("/var/lib/../etc", "/etc"), "alpha", null));
    }

    @Test
    void bindMountsRejectsRelativeContainer() {
        assertThrows(IllegalArgumentException.class,
            () -> BindMountValidator.validate(
                Map.of("/data", "data"), "alpha", null));
    }

    @Test
    void bindMountsRejectsOutsideProject() {
        assertThrows(IllegalArgumentException.class,
            () -> BindMountValidator.validate(
                Map.of("/var/lib/tti-workbench/containers/beta/data", "/data"),
                "alpha",
                "/var/lib/tti-workbench/containers"));
    }

    @Test
    void bindMountsEmptyIsNoop() {
        BindMountValidator.validate(null, "alpha", null);
        BindMountValidator.validate(Map.of(), "alpha", null);
    }

    // ---------------- SessionsClient construction

    @Test
    void sessionsClientConstruction() {
        SessionsClient c = new SessionsClient(
            "localhost", 8443, "http", "ttiowbs_abc");
        assertNotNull(c);
    }

    // ---------------- SessionProxy

    @Test
    void subprotocolConstant() {
        assertEquals("ttio-session-proxy", SessionProxy.SESSION_PROXY_SUBPROTOCOL);
    }

    @Test
    void proxyUrlDefaultScheme() {
        assertEquals("ws://h:8443/v1/sessions/01H/",
            SessionProxy.url("h", 8443, "01H", "ws"));
    }

    @Test
    void proxyUrlWss() {
        assertEquals("wss://h:8443/v1/sessions/01H/",
            SessionProxy.url("h", 8443, "01H", "wss"));
    }

    @Test
    void proxyUrlRejectsEmptyId() {
        assertThrows(IllegalArgumentException.class,
            () -> SessionProxy.url("h", 8443, "", "ws"));
    }

    @Test
    void attachHandshakeDefaultPath() {
        String hs = SessionProxy.buildAttachHandshake("ttiowbs_abc", null);
        assertEquals(
            "{\"action\":\"attach\","
            + "\"token\":\"ttiowbs_abc\","
            + "\"path\":\"/\"}",
            hs);
    }

    @Test
    void attachHandshakePrependsSlash() {
        String hs = SessionProxy.buildAttachHandshake("ttiowbs_abc", "api/kernels");
        assertTrue(hs.contains("\"path\":\"/api/kernels\""));
    }

    @Test
    void attachHandshakeRejectsEmptyToken() {
        assertThrows(IllegalArgumentException.class,
            () -> SessionProxy.buildAttachHandshake("", "/"));
    }

    // ---------------- cross-language anchor

    @Test
    void crossLanguageAttachHandshakeLiteral() {
        // Pinned against the same literal as the Python suite's
        // test_cross_language_attach_handshake_literal.
        String hs = SessionProxy.buildAttachHandshake(
            "ttiowbs_abc", "/api/kernels");
        assertEquals(
            "{\"action\":\"attach\","
            + "\"token\":\"ttiowbs_abc\","
            + "\"path\":\"/api/kernels\"}",
            hs);
    }
}
