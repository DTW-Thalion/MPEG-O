/*
 * tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.handshake.ServerHandshake;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/**
 * Uploads a {@code .tis} byte stream over a WebSocket connection.
 *
 * <p>Wire protocol:</p>
 * <ol>
 *   <li>On open: send leading text frame
 *       <code>{"type":"upload","filename":"&lt;basename&gt;.tio"}</code></li>
 *   <li>Read the {@code .tis} file in 64 KiB chunks; send each as binary.</li>
 *   <li>After last chunk: send trailing text frame
 *       <code>{"type":"end"}</code> and close.</li>
 * </ol>
 */
public final class TisWsUploader {

    private static final int CHUNK_SIZE = 64 * 1024;

    private TisWsUploader() {}

    /**
     * Upload {@code tisPath} to {@code uri} via WebSocket binary frames.
     *
     * @param uri       target URI ({@code ws://} or {@code wss://})
     * @param tisPath   path to the temporary {@code .tis} file to upload
     * @param basename  base filename of the original {@code .tio}
     * @throws Exception on failure
     */
    public static void upload(URI uri, Path tisPath, String basename)
            throws Exception {
        CompletableFuture<Void> done = new CompletableFuture<>();
        UploadingClient client = new UploadingClient(uri, tisPath, basename, done);
        if (!client.connectBlocking(30, TimeUnit.SECONDS)) {
            throw new IOException("WebSocket connect to " + uri + " timed out");
        }
        done.get(120, TimeUnit.SECONDS);
        client.closeBlocking();
    }

    private static final class UploadingClient extends WebSocketClient {

        private final Path tisPath;
        private final String basename;
        private final CompletableFuture<Void> done;

        UploadingClient(URI uri, Path tisPath, String basename,
                        CompletableFuture<Void> done) {
            super(uri);
            this.tisPath  = tisPath;
            this.basename = basename;
            this.done     = done;
        }

        @Override
        public void onOpen(ServerHandshake handshake) {
            Thread t = new Thread(this::doUpload, "tis-ws-upload");
            t.setDaemon(true);
            t.start();
        }

        private void doUpload() {
            try {
                send(leading());
                byte[] buf = new byte[CHUNK_SIZE];
                try (InputStream in = Files.newInputStream(tisPath)) {
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        send(ByteBuffer.wrap(buf, 0, n));
                    }
                }
                send(trailing());
                done.complete(null);
            } catch (Exception ex) {
                done.completeExceptionally(ex);
                close();
            }
        }

        private String leading() {
            return "{" + q("type") + ":" + q("upload") + ","
                 + q("filename") + ":" + q(escapeJson(basename)) + "}";
        }

        private static String trailing() {
            return "{" + q("type") + ":" + q("end") + "}";
        }

        @Override public void onMessage(String message) {}
        @Override public void onMessage(ByteBuffer bytes) {}

        @Override
        public void onClose(int code, String reason, boolean remote) {
            if (!done.isDone()) {
                done.completeExceptionally(new IOException(
                    "WebSocket closed unexpectedly: code=" + code
                    + (reason != null && !reason.isEmpty()
                        ? " reason=" + reason : "")));
            }
        }

        @Override
        public void onError(Exception ex) {
            if (!done.isDone()) done.completeExceptionally(ex);
        }

        /** Wrap s in JSON double-quotes. */
        private static String q(String s) {
            return "\"" + s + "\"";
        }

        private static String escapeJson(String s) {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder(s.length() + 4);
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if      (c == '"')  sb.append("\\\"");
                else if (c == '\\') sb.append("\\\\");
                else sb.append(c);
            }
            return sb.toString();
        }
    }
}
