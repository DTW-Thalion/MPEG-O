/*
 * tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.browser.progress.ProgressTracker;
import javafx.concurrent.Task;

import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Background {@link Task} that encodes a local {@code .tio} dataset into a
 * {@code .tis} transport stream and uploads it to a remote server.
 */
public final class UploadTask extends Task<Void> {

    private final String localPath;
    private final String targetUrl;
    private final String bearerToken;
    private final boolean useChecksum;
    private volatile ProgressListener progressListener;
    private ProgressTracker tracker;

    public UploadTask(String localPath, String targetUrl,
                      String bearerToken, boolean useChecksum) {
        this.localPath   = localPath;
        this.targetUrl   = targetUrl;
        this.bearerToken = bearerToken;
        this.useChecksum = useChecksum;
    }

    public void setProgressListener(ProgressListener listener) {
        this.progressListener = listener;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Encoding .tio to .tis ...");
        Path tis = TisEncoder.encodeToTempFile(localPath, useChecksum);
        try {
            long total = Files.size(tis);
            tracker = new ProgressTracker(
                "uploading", total, -1L, System.currentTimeMillis());
            emit(0L);
            URI uri = URI.create(targetUrl);
            updateMessage("Uploading to " + uri.getHost() + " ...");
            switch (uri.getScheme()) {
                case "http", "https" ->
                    TisHttpUploader.upload(uri, tis, bearerToken);
                case "ws", "wss" ->
                    TisWsUploader.upload(uri, tis, basename(localPath));
                default -> throw new IllegalArgumentException(
                    "Unsupported URL scheme: " + uri.getScheme());
            }
            emit(total);
            updateMessage("Done.");
            return null;
        } finally {
            Files.deleteIfExists(tis);
        }
    }

    private void emit(long bytesDone) {
        ProgressListener l = progressListener;
        if (l == null || tracker == null) return;
        l.onProgress(tracker.sample(bytesDone, 0L, System.currentTimeMillis()));
    }

    private static String basename(String path) {
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash >= 0 ? path.substring(slash + 1) : path;
    }
}
