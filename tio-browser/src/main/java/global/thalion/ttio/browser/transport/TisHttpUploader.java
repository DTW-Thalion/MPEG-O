/*
 * tio-browser — TTI-O dataset browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;

/**
 * Uploads a {@code .tis} byte stream to an HTTP(S) endpoint via PUT.
 *
 * <p>An optional Bearer token is sent as {@code Authorization: Bearer <token>}
 * when {@code bearerToken} is non-blank.</p>
 */
public final class TisHttpUploader {

    private TisHttpUploader() {}

    /**
     * PUT the contents of {@code tisPath} to {@code uri}.
     *
     * @param uri         target URI ({@code http://} or {@code https://})
     * @param tisPath     path to the temporary {@code .tis} file to upload
     * @param bearerToken optional Bearer token; ignored when blank or null
     * @throws IOException          on network or I/O error
     * @throws InterruptedException if the calling thread is interrupted
     */
    public static void upload(URI uri, Path tisPath, String bearerToken)
            throws IOException, InterruptedException {
        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(30))
            .build();

        HttpRequest.Builder req = HttpRequest.newBuilder(uri)
            .timeout(Duration.ofSeconds(120))
            .header("Content-Type", "application/octet-stream")
            .PUT(HttpRequest.BodyPublishers.ofFile(tisPath));

        if (bearerToken != null && !bearerToken.isBlank()) {
            req.header("Authorization", "Bearer " + bearerToken);
        }

        HttpResponse<Void> response = client.send(
            req.build(), HttpResponse.BodyHandlers.discarding());

        int status = response.statusCode();
        if (status < 200 || status >= 300) {
            throw new IOException(
                "HTTP PUT to " + uri + " failed with status " + status);
        }
    }
}
