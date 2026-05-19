/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.WorkbenchClient;
import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.auth.Session;
import global.thalion.ttio.workbench.auth.WorkbenchAuthException;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * GUI-side holder for the workbench connection. Wraps the W2
 * {@link WorkbenchClient} SDK with an observable state machine
 * suitable for binding into JavaFX panels.
 *
 * <p>Lifetime is process-wide via {@link #instance()}; tio-browser
 * holds at most one workbench connection at a time. A future
 * multi-server build could move to a per-window instance with no
 * API change beyond removing the static getter.</p>
 *
 * <p>Threading: {@link #connect}, {@link #disconnect}, and listener
 * dispatch all run on the calling thread. The login dialog calls
 * {@code connect()} from a JavaFX {@code Task.call()} on a worker
 * thread; the status indicator's listener marshals back to the FX
 * thread via {@code Platform.runLater}.</p>
 */
public final class ConnectionManager {

    private static final ConnectionManager INSTANCE = new ConnectionManager();

    /** Process-wide singleton. */
    public static ConnectionManager instance() { return INSTANCE; }

    /** Visible for tests; production code should use {@link #instance()}. */
    public ConnectionManager() {}

    private volatile WorkbenchClient client;
    private volatile ConnectionState state = ConnectionState.DISCONNECTED;
    private volatile String lastMessage = "";
    private final List<ConnectionListener> listeners = new CopyOnWriteArrayList<>();

    /** Current state. */
    public ConnectionState state() { return state; }

    /** Last failure message (for state {@link ConnectionState#FAILED}),
     *  or empty string otherwise. */
    public String lastMessage() { return lastMessage; }

    /** {@code true} when {@link #state()} is {@link ConnectionState#CONNECTED}. */
    public boolean isConnected() { return state == ConnectionState.CONNECTED; }

    /** Current client or {@code null} when not connected. */
    public WorkbenchClient client() { return client; }

    /** Current session or {@code null} when not connected. */
    public Session session() { return client == null ? null : client.session(); }

    public void addListener(ConnectionListener l) { listeners.add(l); }
    public void removeListener(ConnectionListener l) { listeners.remove(l); }

    /**
     * Resolve {@code url}, authenticate via {@code auth}, retain the
     * resulting {@link WorkbenchClient}. Transitions through
     * {@code CONNECTING} on entry and either {@code CONNECTED} (on
     * success) or {@code FAILED} (on auth / network failure).
     *
     * @return the established session (also retained as the
     *         instance's {@link #session()}).
     * @throws WorkbenchAuthException on credential failure;
     *         {@link RuntimeException} on network / URL problems.
     *         State is set to {@code FAILED} before the exception
     *         propagates so listeners see a coherent error trail.
     */
    public Session connect(String url, AuthProvider auth) {
        setState(ConnectionState.CONNECTING, "Connecting to " + url + "...");
        try {
            WorkbenchClient connected = WorkbenchClient.connect(url, auth);
            this.client = connected;
            setState(ConnectionState.CONNECTED,
                "Connected as " + connected.session().username()
                + " @ " + connected.host());
            return connected.session();
        } catch (RuntimeException e) {
            this.client = null;
            setState(ConnectionState.FAILED, summariseError(e));
            throw e;
        }
    }

    /** Drop the cached client; transition to {@link ConnectionState#DISCONNECTED}.
     *  Idempotent. */
    public void disconnect() {
        WorkbenchClient old = this.client;
        this.client = null;
        if (old != null) {
            try { old.close(); }
            catch (RuntimeException ignored) {
                // close() is a no-op in v1.0; tolerate any future
                // revocation failure rather than block the UI.
            }
        }
        setState(ConnectionState.DISCONNECTED, "");
    }

    private void setState(ConnectionState newState, String message) {
        this.state = newState;
        this.lastMessage = message == null ? "" : message;
        for (ConnectionListener l : listeners) {
            try { l.onStateChanged(newState, lastMessage); }
            catch (RuntimeException ignored) {
                // a listener throwing must not block other listeners
                // or the caller. The chained finally-throw in connect()
                // is enough to surface the underlying error.
            }
        }
    }

    private static String summariseError(Throwable t) {
        // Prefer the message; fall back to the class name so the UI
        // never shows a blank tooltip.
        String msg = t.getMessage();
        if (msg != null && !msg.isEmpty()) return msg;
        return t.getClass().getSimpleName();
    }
}
