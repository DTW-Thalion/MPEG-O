/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.WorkbenchClient;
import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.sessions.Session;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class SessionListTest {

    private static WorkbenchClient connectedClient(String url) {
        // attachUrl only needs the resolved endpoint (host/port/wsScheme);
        // a stub auth provider supplies a valid session so connect()
        // succeeds without a daemon.
        return WorkbenchClient.connect(url, new AuthProvider() {
            @Override public String username() { return "alice"; }
            @Override public global.thalion.ttio.workbench.auth.Session
                    authenticate(String h, int p, String scheme) {
                return new global.thalion.ttio.workbench.auth.Session(
                    "ttiowbs_" + "x".repeat(43), "alice", "U",
                    Set.of(), List.of(), 2_000_000_000L,
                    "stub", "S");
            }
        });
    }

    private static Session session(String id, String status) {
        return new Session(
            id, status, "alpha", "alice", "shell", 1700000000L,
            status.equals("running") ? 49152 : null,
            null, null, null, null, null, null, null, null,
            null, List.of(), Map.of(), Map.of());
    }

    @Test
    void attachUrlForRunningSession() {
        WorkbenchClient client = connectedClient("wss://biobank.example.com:8443/transport");
        Session s = session("01HSESS", "running");
        String url = SessionList.attachUrl(s, client);
        assertEquals("wss://biobank.example.com:8443/v1/sessions/01HSESS/", url);
    }

    @Test
    void attachUrlNullForNonRunningSession() {
        WorkbenchClient client = connectedClient("wss://biobank.example.com:8443/transport");
        assertNull(SessionList.attachUrl(session("01H", "starting"), client));
        assertNull(SessionList.attachUrl(session("01H", "terminated"), client));
        assertNull(SessionList.attachUrl(session("01H", "failed"), client));
    }

    @Test
    void attachUrlNullForNullArgs() {
        WorkbenchClient client = connectedClient("ws://localhost:8443");
        assertNull(SessionList.attachUrl(null, client));
        assertNull(SessionList.attachUrl(session("01H", "running"), null));
    }

    @Test
    void attachUrlUsesWsSchemeForPlainEndpoint() {
        WorkbenchClient client = connectedClient("ws://localhost:8443");
        String url = SessionList.attachUrl(session("01HSESS", "running"), client);
        assertEquals("ws://localhost:8443/v1/sessions/01HSESS/", url);
    }
}
