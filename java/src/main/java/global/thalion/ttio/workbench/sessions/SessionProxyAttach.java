/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.sessions;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.drafts.Draft_6455;
import org.java_websocket.handshake.ServerHandshake;
import org.java_websocket.protocols.IProtocol;
import org.java_websocket.protocols.Protocol;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Callback-driven WS attach helper for interactive sessions.
 *
 * <p>Opens {@code wss://host:port/v1/sessions/{id}/} with the
 * {@code ttio-session-proxy} subprotocol, sends the JSON attach
 * frame, then pumps raw bytes bidirectionally between a caller-
 * supplied {@link InputStream} (typically {@code System.in}) and
 * an {@link OutputStream} (typically {@code System.out}).</p>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.session_proxy.SessionProxyAttach}.</p>
 */
public final class SessionProxyAttach {

    public static final int DEFAULT_CHUNK_SIZE = 16 * 1024;

    private final String host;
    private final int port;
    private final String sessionId;
    private final String token;
    private final String path;
    private final String scheme;
    private final long connectTimeoutMs;

    private SessionProxyAttach(Builder b) {
        this.host       = b.host;
        this.port       = b.port;
        this.sessionId  = b.sessionId;
        this.token      = b.token;
        this.path       = b.path == null ? "/" : b.path;
        this.scheme     = b.scheme == null ? "ws" : b.scheme;
        this.connectTimeoutMs = b.connectTimeoutMs;
    }

    public static Builder builder() { return new Builder(); }

    public static final class Builder {
        private String host;
        private int port;
        private String sessionId;
        private String token;
        private String path = "/";
        private String scheme = "ws";
        private long connectTimeoutMs = 10_000L;

        public Builder host(String s)              { this.host = s; return this; }
        public Builder port(int v)                  { this.port = v; return this; }
        public Builder sessionId(String s)          { this.sessionId = s; return this; }
        public Builder token(String s)              { this.token = s; return this; }
        public Builder path(String s)               { this.path = s; return this; }
        public Builder scheme(String s)             { this.scheme = s; return this; }
        public Builder connectTimeoutMs(long ms)    { this.connectTimeoutMs = ms; return this; }

        public SessionProxyAttach build() {
            return new SessionProxyAttach(this);
        }
    }

    /** Outcome of an attach session. */
    public record Result(int closeCode, String closeReason,
                          long bytesToBackend, long bytesFromBackend) {}

    /**
     * Attach and pump bytes until the WS closes. Blocks the calling
     * thread; run on a worker thread for non-blocking use.
     */
    public Result run(InputStream stdin, OutputStream stdout, int chunkSize) {
        URI uri = URI.create(SessionProxy.url(host, port, sessionId, scheme));
        ProxyDriver driver = new ProxyDriver(uri, token, path, stdin, stdout, chunkSize);
        try {
            if (!driver.connectBlocking(connectTimeoutMs, TimeUnit.MILLISECONDS)) {
                throw new RuntimeException(
                    "session-proxy WS connect timed out after "
                    + connectTimeoutMs + " ms");
            }
            return driver.future().get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            driver.close();
            throw new RuntimeException("session-proxy interrupted", e);
        } catch (Exception e) {
            driver.close();
            Throwable cause = e.getCause() != null ? e.getCause() : e;
            throw new RuntimeException("session-proxy error: " + cause, cause);
        }
    }

    private static Draft_6455 draftWithSubprotocol() {
        List<IProtocol> protocols =
            List.of(new Protocol(SessionProxy.SESSION_PROXY_SUBPROTOCOL));
        return new Draft_6455(Collections.emptyList(), protocols);
    }

    // ----------------------------------------------------------------
    // driver inner class
    // ----------------------------------------------------------------

    private static final class ProxyDriver extends WebSocketClient {
        private final String token;
        private final String path;
        private final InputStream stdin;
        private final OutputStream stdout;
        private final int chunkSize;
        private final CompletableFuture<Result> future = new CompletableFuture<>();
        private final AtomicLong toBackend = new AtomicLong(0);
        private final AtomicLong fromBackend = new AtomicLong(0);
        private volatile Thread pumpThread;

        ProxyDriver(URI uri, String token, String path,
                     InputStream stdin, OutputStream stdout,
                     int chunkSize) {
            super(uri, draftWithSubprotocol());
            this.token  = token;
            this.path   = path;
            this.stdin  = stdin;
            this.stdout = stdout;
            this.chunkSize = chunkSize;
        }

        CompletableFuture<Result> future() { return future; }

        @Override
        public void onOpen(ServerHandshake h) {
            send(SessionProxy.buildAttachHandshake(token, path));
            pumpThread = new Thread(this::pumpStdin, "ttio-session-pump");
            pumpThread.setDaemon(true);
            pumpThread.start();
        }

        private void pumpStdin() {
            byte[] buf = new byte[chunkSize];
            try {
                while (!future.isDone()) {
                    int n = stdin.read(buf);
                    if (n < 0) break;
                    if (n == 0) continue;
                    send(ByteBuffer.wrap(buf, 0, n));
                    toBackend.addAndGet(n);
                }
            } catch (Exception e) {
                if (!future.isDone()) {
                    future.completeExceptionally(
                        new RuntimeException("session-proxy stdin pump", e));
                }
            }
        }

        @Override
        public void onMessage(String message) {
            // v1.0 contract: no server-emitted TEXT after attach.
        }

        @Override
        public synchronized void onMessage(ByteBuffer bytes) {
            byte[] raw = new byte[bytes.remaining()];
            bytes.get(raw);
            try {
                stdout.write(raw);
                stdout.flush();
                fromBackend.addAndGet(raw.length);
            } catch (Exception e) {
                future.completeExceptionally(
                    new RuntimeException("session-proxy stdout write", e));
            }
        }

        @Override
        public void onClose(int code, String reason, boolean remote) {
            if (!future.isDone()) {
                future.complete(new Result(code, reason,
                    toBackend.get(), fromBackend.get()));
            }
        }

        @Override
        public void onError(Exception ex) {
            if (!future.isDone()) future.completeExceptionally(ex);
        }
    }
}
