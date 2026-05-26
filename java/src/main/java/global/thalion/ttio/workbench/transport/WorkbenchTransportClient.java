/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import global.thalion.ttio.workbench.WorkbenchJson;
import global.thalion.ttio.workbench.auth.Session;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.OutputMode;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.ServerFrame;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.ServerFrameKind;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.drafts.Draft_6455;
import org.java_websocket.handshake.ServerHandshake;
import org.java_websocket.protocols.IProtocol;
import org.java_websocket.protocols.Protocol;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.OptionalInt;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Workbench-aware sibling of {@link global.thalion.ttio.transport.TransportClient}.
 *
 * <p>Speaks the {@code ttio-transport} WS subprotocol against
 * {@code tti-workbench-server} v1.0.0+. Supports authenticated
 * uploads, authenticated downloads (with optional selective-access
 * filtering), and resumable uploads via {@link ResumeState}.</p>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.transport.UploadClient} /
 * {@code DownloadClient}. The JSON shapes on the wire are
 * byte-identical to the Python builder so the cross-language
 * equivalence test can compare them directly.</p>
 *
 * <p>Thread model: one client instance drives one operation
 * (upload OR download). For concurrent operations, construct
 * multiple instances. The class is not designed for re-use across
 * operations.</p>
 */
public final class WorkbenchTransportClient {

    private final String host;
    private final int port;
    private final boolean useTls;
    private final String token;
    private final String owner;
    private final long defaultTimeoutMs;
    private final int chunkSize;

    /** Construct with explicit session. Required for uploads (the
     *  daemon's auth gate uses {@code session.username()} as the
     *  upload owner). */
    public static WorkbenchTransportClient forSession(
            String host, int port, Session session) {
        return new Builder(host, port).session(session).build();
    }

    /** Construct with a raw bearer token + owner string. Useful for
     *  CLI paths that have a token but no fully-populated session. */
    public static WorkbenchTransportClient forToken(
            String host, int port, String token, String owner) {
        return new Builder(host, port).token(token).owner(owner).build();
    }

    public static Builder builder(String host, int port) {
        return new Builder(host, port);
    }

    private WorkbenchTransportClient(Builder b) {
        this.host             = Objects.requireNonNull(b.host, "host");
        this.port             = b.port;
        this.useTls           = b.useTls;
        this.token            = Objects.requireNonNull(b.token, "token");
        this.owner            = Objects.requireNonNull(b.owner, "owner");
        this.defaultTimeoutMs = b.defaultTimeoutMs;
        this.chunkSize        = b.chunkSize;
    }

    /** Default per-WS-frame size when chunking a fully-buffered payload. */
    public static final int DEFAULT_CHUNK_SIZE = 64 * 1024;

    // ---------------- upload ----------------

    /** Outcome of a successful upload. */
    public record UploadResult(String containerUri,
                                long lastAckedAuSequence,
                                String resumeHandle) {}

    /** Upload a fully-buffered {@code .tis} byte payload.
     *
     *  <p>Memory cost: at least {@code payload.length} heap for the
     *  caller-supplied byte[] (this method does not copy). For
     *  multi-MB payloads, prefer
     *  {@link #upload(String, String, Path, ResumeState, TransferProgress)}
     *  which streams from a file in {@code chunkSize}-bounded slices.</p>
     */
    public UploadResult upload(String project, String containerUri, byte[] payload) {
        return upload(project, containerUri, payload, null, null);
    }

    /** Upload with optional resume state. */
    public UploadResult upload(String project, String containerUri,
                                 byte[] payload, ResumeState resume) {
        return upload(project, containerUri, payload, resume, null);
    }

    /** Upload with optional resume state + a progress callback.
     *  {@code progress} (nullable) is invoked with
     *  {@code (bytesSent, payload.length)} as chunks are enqueued,
     *  plus a final {@code (length, length)} once fully sent. */
    public UploadResult upload(String project, String containerUri,
                                 byte[] payload, ResumeState resume,
                                 TransferProgress progress) {
        // Wrap the byte[] in a BytesPayloadSource and dispatch through
        // the unified driver path. No copy — the byte[] is read in-place.
        PayloadSource src = new BytesPayloadSource(payload);
        try {
            return runUpload(project, containerUri, src, resume, progress);
        } finally {
            try { src.close(); } catch (IOException ignored) {}
        }
    }

    /** Streaming upload — read the {@code .tis} payload from a file
     *  on disk in {@code chunkSize}-bounded slices instead of slurping
     *  the whole thing into a {@code byte[]}.
     *
     *  <p>Peak heap during this call is O({@code chunkSize}) — one
     *  chunk read into a ByteBuffer and at most one chunk in flight
     *  on the WS thread — regardless of {@code payloadFile} size. Use
     *  this overload for multi-GB {@code .tis} uploads where the
     *  byte[] entry point would OOM long before bytes hit the wire.</p>
     *
     *  <p>The {@link TransferProgress} callback fires
     *  {@code (bytesSent, totalBytes)} with the same shape as the
     *  byte[] path; downstream
     *  {@code PhaseProgress} / {@code ProgressTracker} wiring is
     *  byte-equivalent.</p>
     */
    public UploadResult upload(String project, String containerUri,
                                 Path payloadFile,
                                 ResumeState resume,
                                 TransferProgress progress) throws IOException {
        long totalBytes = Files.size(payloadFile);
        FileChannel ch = FileChannel.open(payloadFile, StandardOpenOption.READ);
        PayloadSource src = new FilePayloadSource(ch, totalBytes);
        try {
            return runUpload(project, containerUri, src, resume, progress);
        } finally {
            try { src.close(); } catch (IOException ignored) {}
        }
    }

    /** Streaming-upload convenience overload without resume / progress. */
    public UploadResult upload(String project, String containerUri,
                                 Path payloadFile) throws IOException {
        return upload(project, containerUri, payloadFile, null, null);
    }

    /** Shared driver-runner used by both the byte[] and Path overloads. */
    private UploadResult runUpload(String project, String containerUri,
                                     PayloadSource source,
                                     ResumeState resume,
                                     TransferProgress progress) {
        URI uri = wsUri();
        UploadDriver driver = new UploadDriver(
            uri, token, owner, project, containerUri,
            resume == null ? null : resume.resumeHandle(),
            source, chunkSize, progress);

        if (!driver.connectBlockingWith(defaultTimeoutMs)) {
            throw new WorkbenchTransportException.Handshake(
                "WS connect timed out after " + defaultTimeoutMs + " ms");
        }
        try {
            return driver.future().get(defaultTimeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException e) {
            driver.close();
            throw new WorkbenchTransportException.Upload(
                "upload timed out after " + defaultTimeoutMs + " ms",
                OptionalInt.empty(), null,
                driver.lastAck(), driver.handle());
        } catch (Exception e) {
            driver.close();
            Throwable cause = e.getCause() != null ? e.getCause() : e;
            if (cause instanceof WorkbenchTransportException w) throw w;
            throw new WorkbenchTransportException.Upload(
                "upload failed: " + cause,
                OptionalInt.empty(), null,
                driver.lastAck(), driver.handle());
        } finally {
            driver.closeQuietly();
        }
    }

    // ---------------- download ----------------

    /** Outcome of a successful download. */
    public record DownloadResult(String containerUri,
                                   byte[] payload,
                                   List<Map<String, Object>> statsFrames,
                                   int binaryFrameCount,
                                   Map<String, Object> terminalFrame) {}

    /** Download a container with no filter (full content, binary mode). */
    public DownloadResult download(String containerUri) {
        return download(containerUri, null, OutputMode.BINARY, 0);
    }

    /** Download with optional selective-access filter and output mode. */
    public DownloadResult download(String containerUri,
                                     Map<String, Object> filter,
                                     OutputMode outputMode,
                                     int maxAu) {
        return download(containerUri, filter, outputMode, maxAu, null);
    }

    /** Download with a progress callback. The server streams without
     *  a known content length, so {@code progress} is invoked with
     *  {@code (bytesReceived, TransferProgress.UNKNOWN_TOTAL)} as
     *  binary frames arrive — consumers show bytes-so-far. */
    public DownloadResult download(String containerUri,
                                     Map<String, Object> filter,
                                     OutputMode outputMode,
                                     int maxAu,
                                     TransferProgress progress) {
        URI uri = wsUri();
        DownloadDriver driver = new DownloadDriver(
            uri, token, owner, containerUri,
            outputMode, filter, maxAu, progress);

        if (!driver.connectBlockingWith(defaultTimeoutMs)) {
            throw new WorkbenchTransportException.Handshake(
                "WS connect timed out after " + defaultTimeoutMs + " ms");
        }
        try {
            return driver.future().get(defaultTimeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException e) {
            driver.close();
            throw new WorkbenchTransportException.Download(
                "download timed out after " + defaultTimeoutMs + " ms",
                OptionalInt.empty(), null);
        } catch (Exception e) {
            driver.close();
            Throwable cause = e.getCause() != null ? e.getCause() : e;
            if (cause instanceof WorkbenchTransportException w) throw w;
            throw new WorkbenchTransportException.Download(
                "download failed: " + cause,
                OptionalInt.empty(), null);
        } finally {
            driver.closeQuietly();
        }
    }

    private URI wsUri() {
        return URI.create((useTls ? "wss" : "ws") + "://" + host + ":" + port + "/transport");
    }

    private static Draft_6455 draftWithSubprotocol() {
        // Java-WebSocket's `Draft_6455(extensions, protocols)` ctor
        // sets the Sec-WebSocket-Protocol header. The daemon's
        // libwebsockets mount requires `ttio-transport`.
        List<IProtocol> protocols = List.of(new Protocol(WorkbenchHandshake.WS_SUBPROTOCOL));
        return new Draft_6455(Collections.emptyList(), protocols);
    }

    // ---------------- builder ----------------

    public static final class Builder {
        private final String host;
        private final int port;
        private boolean useTls = false;
        private String token;
        private String owner;
        private long defaultTimeoutMs = 30_000L;
        private int chunkSize = DEFAULT_CHUNK_SIZE;

        Builder(String host, int port) {
            this.host = host;
            this.port = port;
        }

        public Builder session(Session s) {
            this.token = s.token();
            this.owner = s.username();
            return this;
        }
        public Builder token(String token) { this.token = token; return this; }
        public Builder owner(String owner) { this.owner = owner; return this; }
        public Builder useTls(boolean v)    { this.useTls = v; return this; }
        public Builder defaultTimeoutMs(long v) {
            this.defaultTimeoutMs = v;
            return this;
        }
        public Builder chunkSize(int v) { this.chunkSize = v; return this; }

        public WorkbenchTransportClient build() {
            return new WorkbenchTransportClient(this);
        }
    }

    // ----------------------------------------------------------------
    // upload driver
    // ----------------------------------------------------------------

    private static final class UploadDriver extends WebSocketClient {
        private final String token;
        private final String owner;
        private final String project;
        private final String containerUri;
        private final String resumeHandle;
        private final PayloadSource source;
        private final long totalBytes;
        private final int chunkSize;
        private final TransferProgress progress;

        private final CompletableFuture<UploadResult> future = new CompletableFuture<>();
        private final AtomicLong lastAck = new AtomicLong(-1L);
        private volatile String handle;
        private volatile boolean handshakeAcked = false;

        UploadDriver(URI uri, String token, String owner, String project,
                       String containerUri, String resumeHandle,
                       PayloadSource source, int chunkSize,
                       TransferProgress progress) {
            super(uri, draftWithSubprotocol());
            this.token = token;
            this.owner = owner;
            this.project = project;
            this.containerUri = containerUri;
            this.resumeHandle = resumeHandle;
            this.source = source;
            this.totalBytes = source.size();
            this.chunkSize = chunkSize;
            this.progress = progress;
        }

        long lastAck()    { return lastAck.get(); }
        String handle()   { return handle; }
        CompletableFuture<UploadResult> future() { return future; }

        boolean connectBlockingWith(long timeoutMs) {
            try {
                return connectBlocking(timeoutMs, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
        }

        @Override
        public void onOpen(ServerHandshake h) {
            String hs = WorkbenchHandshake.buildUploadHandshake(
                owner, project, containerUri, token, resumeHandle);
            send(hs);
        }

        @Override
        public void onMessage(String message) {
            try {
                ServerFrame frame = WorkbenchHandshake.parseServerFrame(message);
                switch (frame.kind()) {
                    case ACK -> handleAck(frame.body());
                    case ERROR -> {
                        String reason = stringField(frame.body(), "message",
                                            stringField(frame.body(), "reason", ""));
                        future.completeExceptionally(
                            new WorkbenchTransportException.Upload(
                                handshakeAcked
                                    ? "server error mid-upload: " + reason
                                    : "server rejected handshake: " + reason,
                                OptionalInt.empty(), reason,
                                lastAck.get(), handle));
                    }
                    case DONE -> {
                        String uri = stringField(frame.body(), "container_uri", containerUri);
                        future.complete(new UploadResult(
                            uri, lastAck.get(),
                            handle == null ? "" : handle));
                    }
                }
            } catch (IllegalArgumentException e) {
                future.completeExceptionally(
                    new WorkbenchTransportException("server frame parse error: " + e, e));
            }
        }

        private void handleAck(Map<String, Object> body) {
            Object seq = body.get("au_sequence");
            if (seq instanceof Number n) {
                lastAck.updateAndGet(prev -> Math.max(prev, n.longValue()));
            }
            if (!handshakeAcked) {
                Object handleField = body.get("handle");
                if (handleField instanceof String s) handle = s;
                handshakeAcked = true;
                // Spawn the payload pump on a background thread to
                // avoid blocking the WS receiver's onMessage callback.
                Thread pump = new Thread(this::pumpPayload, "ttio-upload-pump");
                pump.setDaemon(true);
                pump.start();
            }
        }

        private void pumpPayload() {
            // We allocate a fresh ByteBuffer per chunk. The Java-WebSocket
            // layer retains the buffer reference until the I/O thread
            // drains the frame, so reusing one buffer across send() calls
            // would corrupt earlier-queued frames. Allocating per chunk
            // means peak heap is O(chunkSize * outstanding-in-WS-queue);
            // we cap that via hasBufferedData() backpressure below so
            // steady-state heap stays bounded regardless of payload size.
            try {
                long off = 0L;
                reportProgress(0L, totalBytes);
                while (off < totalBytes && !future.isDone()) {
                    // Backpressure: if the WS layer hasn't drained the
                    // previous frame yet, yield briefly so the outbound
                    // queue can't grow unboundedly on a slow link.
                    int spins = 0;
                    while (hasBufferedData() && !future.isDone()
                            && spins < 100_000) {
                        try { Thread.sleep(1); }
                        catch (InterruptedException ie) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                        spins++;
                    }
                    long remaining = totalBytes - off;
                    int want = (int) Math.min((long) chunkSize, remaining);
                    ByteBuffer chunk = ByteBuffer.allocate(want);
                    int n = source.read(chunk, off);
                    if (n < 0) break;          // EOF
                    if (n == 0) continue;      // spurious zero — retry
                    chunk.flip();
                    send(chunk);
                    off += n;
                    reportProgress(off, totalBytes);
                }
            } catch (Exception e) {
                future.completeExceptionally(
                    new WorkbenchTransportException.Upload(
                        "send failure: " + e,
                        OptionalInt.empty(), null,
                        lastAck.get(), handle));
            }
        }

        private void reportProgress(long done, long total) {
            if (progress == null) return;
            try { progress.onProgress(done, total); }
            catch (RuntimeException ignored) {
                // A throwing progress callback must not abort the
                // upload (TransferProgress contract).
            }
        }

        @Override
        public void onMessage(ByteBuffer bytes) {
            // Upload path never receives BINARY from the server.
        }

        @Override
        public void onClose(int code, String reason, boolean remote) {
            if (!future.isDone()) {
                future.completeExceptionally(
                    new WorkbenchTransportException.Upload(
                        "server closed before `done`: code=" + code +
                        " reason=" + reason,
                        OptionalInt.of(code), reason,
                        lastAck.get(), handle));
            }
        }

        @Override
        public void onError(Exception ex) {
            if (!future.isDone()) {
                future.completeExceptionally(
                    new WorkbenchTransportException("upload WS error: " + ex, ex));
            }
        }

        void closeQuietly() {
            try { close(); } catch (Exception ignored) {}
        }
    }

    // ----------------------------------------------------------------
    // download driver
    // ----------------------------------------------------------------

    private static final class DownloadDriver extends WebSocketClient {
        private final String token;
        private final String owner;
        private final String containerUri;
        private final OutputMode outputMode;
        private final Map<String, Object> filter;
        private final int maxAu;
        private final TransferProgress progress;

        private final CompletableFuture<DownloadResult> future = new CompletableFuture<>();
        private final ByteArrayOutputStream payloadBuf = new ByteArrayOutputStream();
        private final ConcurrentLinkedQueue<Map<String, Object>> stats =
            new ConcurrentLinkedQueue<>();
        private int binaryFrameCount = 0;
        private volatile Map<String, Object> terminal;

        DownloadDriver(URI uri, String token, String owner,
                         String containerUri, OutputMode mode,
                         Map<String, Object> filter, int maxAu,
                         TransferProgress progress) {
            super(uri, draftWithSubprotocol());
            this.token = token;
            this.owner = owner;
            this.containerUri = containerUri;
            this.outputMode = mode == null ? OutputMode.BINARY : mode;
            this.filter = filter;
            this.maxAu = maxAu;
            this.progress = progress;
        }

        CompletableFuture<DownloadResult> future() { return future; }

        boolean connectBlockingWith(long timeoutMs) {
            try {
                return connectBlocking(timeoutMs, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
        }

        @Override
        public void onOpen(ServerHandshake h) {
            String hs = WorkbenchHandshake.buildDownloadHandshake(
                containerUri, token, owner, outputMode, filter, maxAu);
            send(hs);
        }

        @Override
        public void onMessage(String message) {
            try {
                ServerFrame frame = WorkbenchHandshake.parseServerFrame(message);
                switch (frame.kind()) {
                    case ACK -> {
                        // Mid-stream AU stats / progress frames lack
                        // the post-handshake `handle` field; they're
                        // stats frames.
                        stats.add(frame.body());
                    }
                    case DONE -> {
                        terminal = frame.body();
                        future.complete(buildResult());
                    }
                    case ERROR -> {
                        String reason = stringField(frame.body(), "reason",
                                            stringField(frame.body(), "message", ""));
                        future.completeExceptionally(
                            new WorkbenchTransportException.Download(
                                "server error: " + reason,
                                OptionalInt.empty(), reason));
                    }
                }
            } catch (IllegalArgumentException e) {
                future.completeExceptionally(
                    new WorkbenchTransportException("server frame parse error: " + e, e));
            }
        }

        @Override
        public synchronized void onMessage(ByteBuffer bytes) {
            byte[] raw = new byte[bytes.remaining()];
            bytes.get(raw);
            try {
                payloadBuf.write(raw);
            } catch (java.io.IOException e) {
                future.completeExceptionally(
                    new WorkbenchTransportException("payload buffer write error", e));
                return;
            }
            binaryFrameCount++;
            if (progress != null) {
                // Server streams without a known content length;
                // report bytes-so-far with an unknown total.
                try {
                    progress.onProgress(payloadBuf.size(),
                                        TransferProgress.UNKNOWN_TOTAL);
                } catch (RuntimeException ignored) {
                    // Throwing callback must not abort the download.
                }
            }
        }

        @Override
        public void onClose(int code, String reason, boolean remote) {
            if (!future.isDone()) {
                if (terminal != null) {
                    future.complete(buildResult());
                } else {
                    future.completeExceptionally(
                        new WorkbenchTransportException.Download(
                            "server closed before `done`: code=" + code +
                            " reason=" + reason,
                            OptionalInt.of(code), reason));
                }
            }
        }

        @Override
        public void onError(Exception ex) {
            if (!future.isDone()) {
                future.completeExceptionally(
                    new WorkbenchTransportException("download WS error: " + ex, ex));
            }
        }

        private DownloadResult buildResult() {
            String uri = stringField(terminal, "container_uri", containerUri);
            return new DownloadResult(
                uri,
                payloadBuf.toByteArray(),
                new ArrayList<>(stats),
                binaryFrameCount,
                Collections.unmodifiableMap(new LinkedHashMap<>(terminal)));
        }

        void closeQuietly() {
            try { close(); } catch (Exception ignored) {}
        }
    }

    private static String stringField(Map<String, Object> m, String key, String fallback) {
        if (m == null) return fallback;
        Object v = m.get(key);
        return (v instanceof String s) ? s : fallback;
    }
}
