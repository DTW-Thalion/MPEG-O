/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.auth.InvalidCredentialsException;
import global.thalion.ttio.workbench.auth.Session;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pure-Java unit tests for {@link ConnectionManager}. Uses a stub
 * {@link AuthProvider} so no daemon is needed.
 */
class ConnectionManagerTest {

    private static Session fakeSession(String username) {
        return new Session(
            "ttiowbs_" + "x".repeat(43),
            username,
            "01HXYUSR",
            Set.of("containers.read.own_project"),
            List.of("alpha"),
            2_000_000_000L,
            "password-totp",
            "01HXYSES");
    }

    private static final class StubAuth implements AuthProvider {
        private final boolean succeed;
        private final String message;

        StubAuth(boolean succeed, String message) {
            this.succeed = succeed;
            this.message = message;
        }

        @Override public String username() { return "alice"; }

        @Override
        public Session authenticate(String host, int port, String scheme) {
            if (!succeed) throw new InvalidCredentialsException(message);
            return fakeSession("alice");
        }
    }

    @Test
    void initialStateIsDisconnected() {
        ConnectionManager m = new ConnectionManager();
        assertSame(ConnectionState.DISCONNECTED, m.state());
        assertFalse(m.isConnected());
        assertNull(m.client());
        assertNull(m.session());
        assertEquals("", m.lastMessage());
    }

    @Test
    void connectTransitionsThroughConnectingToConnected() {
        ConnectionManager m = new ConnectionManager();
        List<ConnectionState> seen = new ArrayList<>();
        m.addListener((s, msg) -> seen.add(s));

        Session s = m.connect("ws://localhost:8443", new StubAuth(true, null));

        assertEquals("alice", s.username());
        assertTrue(m.isConnected());
        assertNotNull(m.client());
        assertSame(ConnectionState.CONNECTED, m.state());
        assertEquals(
            List.of(ConnectionState.CONNECTING, ConnectionState.CONNECTED),
            seen);
    }

    @Test
    void connectFailureTransitionsToFailedAndRethrows() {
        ConnectionManager m = new ConnectionManager();
        List<ConnectionState> seen = new ArrayList<>();
        m.addListener((s, msg) -> seen.add(s));

        InvalidCredentialsException ex = assertThrows(
            InvalidCredentialsException.class,
            () -> m.connect("ws://localhost:8443",
                new StubAuth(false, "bad password")));
        assertTrue(ex.getMessage().contains("bad password"));

        assertSame(ConnectionState.FAILED, m.state());
        assertFalse(m.isConnected());
        assertNull(m.client());
        assertEquals("bad password", m.lastMessage());
        assertEquals(
            List.of(ConnectionState.CONNECTING, ConnectionState.FAILED),
            seen);
    }

    @Test
    void disconnectFromConnectedTransitionsToDisconnected() {
        ConnectionManager m = new ConnectionManager();
        m.connect("ws://localhost:8443", new StubAuth(true, null));
        assertSame(ConnectionState.CONNECTED, m.state());

        List<ConnectionState> seen = new ArrayList<>();
        m.addListener((s, msg) -> seen.add(s));

        m.disconnect();

        assertSame(ConnectionState.DISCONNECTED, m.state());
        assertFalse(m.isConnected());
        assertNull(m.client());
        assertNull(m.session());
        assertEquals(List.of(ConnectionState.DISCONNECTED), seen);
    }

    @Test
    void disconnectFromDisconnectedIsIdempotent() {
        ConnectionManager m = new ConnectionManager();
        // No exception, no state change other than a listener notification.
        List<ConnectionState> seen = new ArrayList<>();
        m.addListener((s, msg) -> seen.add(s));
        m.disconnect();
        m.disconnect();
        assertSame(ConnectionState.DISCONNECTED, m.state());
        assertEquals(2, seen.size());  // notifies each call -- harmless
    }

    @Test
    void removeListenerStopsNotifications() {
        ConnectionManager m = new ConnectionManager();
        List<ConnectionState> seen = new ArrayList<>();
        ConnectionListener l = (s, msg) -> seen.add(s);
        m.addListener(l);
        m.connect("ws://localhost:8443", new StubAuth(true, null));
        assertEquals(2, seen.size());

        m.removeListener(l);
        m.disconnect();
        // Removed listener should NOT see the disconnect.
        assertEquals(2, seen.size());
    }

    @Test
    void listenerThatThrowsDoesNotBlockOtherListeners() {
        ConnectionManager m = new ConnectionManager();
        List<ConnectionState> seen2 = new ArrayList<>();
        m.addListener((s, msg) -> { throw new RuntimeException("boom"); });
        m.addListener((s, msg) -> seen2.add(s));

        // Throwing listener does not propagate or block siblings.
        m.connect("ws://localhost:8443", new StubAuth(true, null));
        assertEquals(
            List.of(ConnectionState.CONNECTING, ConnectionState.CONNECTED),
            seen2);
    }

    @Test
    void reconnectAfterFailureSucceeds() {
        ConnectionManager m = new ConnectionManager();
        assertThrows(InvalidCredentialsException.class, () ->
            m.connect("ws://localhost:8443", new StubAuth(false, "first try")));
        assertSame(ConnectionState.FAILED, m.state());

        Session s = m.connect("ws://localhost:8443", new StubAuth(true, null));
        assertEquals("alice", s.username());
        assertSame(ConnectionState.CONNECTED, m.state());
    }
}
