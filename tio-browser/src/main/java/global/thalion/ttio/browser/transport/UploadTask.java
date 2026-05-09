/*
 * tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

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

    public UploadTask(String localPath, String targetUrl,
                      String bearerToken, boolean useChecksum) {
        this.localPath   = localPath;
        this.targetUrl   = targetUrl;
        this.bearerToken = bearerToken;
        this.useChecksum = useChecksum;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Encoding .tio to .tis ...");
        Path tis = TisEncoder.encodeToTempFile(localPath, useChecksum);
        try {
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
            updateMessage("Done.");
            return null;
        } finally {
            Files.deleteIfExists(tis);
        }
    }

    private static String basename(String path) {
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash >= 0 ? path.substring(slash + 1) : path;
    }
}
