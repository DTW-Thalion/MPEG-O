/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;
import java.util.Optional;

/**
 * Internal REST helper shared by {@code cohort}, {@code pipeline},
 * and {@code jobs} clients. Wraps {@code java.net.http.HttpClient}.
 *
 * <p>Cross-language equivalent: Python {@code ttio.workbench._http}.</p>
 *
 * <p>Marked {@code public} only because the sub-packages need to
 * call into it. Treat as internal -- not part of the SDK's
 * stability promise.</p>
 */
public final class WorkbenchHttp {

    public static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(10);

    private WorkbenchHttp() {}

    /** Result of a REST call: HTTP status + parsed body (Map / List /
     *  String / Number / Boolean / null per WorkbenchJson). */
    public record Response(int status, Object body) {
        public Optional<String> errorMessage() {
            if (body instanceof Map<?, ?> m) {
                Object err = m.get("error");
                if (err instanceof String s) return Optional.of(s);
            }
            return Optional.empty();
        }
    }

    /** Non-2xx HTTP failure. */
    public static final class WorkbenchHttpException extends RuntimeException {
        private final int status;
        private final transient Object body;

        public WorkbenchHttpException(String message, int status, Object body) {
            super(message);
            this.status = status;
            this.body = body;
        }

        public int status() { return status; }
        public Object body() { return body; }
    }

    /** Issue a JSON REST call. */
    public static Response jsonRequest(
            String method,
            String host, int port, String path,
            String scheme,
            String token,
            Map<String, Object> body,
            Duration timeout) {
        URI url = URI.create(scheme + "://" + host + ":" + port + path);
        HttpRequest.Builder b = HttpRequest.newBuilder(url)
            .timeout(timeout == null ? DEFAULT_TIMEOUT : timeout)
            .header("Accept", "application/json");
        if (token != null && !token.isEmpty()) {
            b.header("Authorization", "Bearer " + token);
        }
        if (body != null) {
            b.header("Content-Type", "application/json");
            // Compact encoding -- byte-matches Python's
            // json.dumps(..., separators=(",", ":")).
            b.method(method, HttpRequest.BodyPublishers.ofString(
                WorkbenchJson.encode(body)));
        } else {
            b.method(method, HttpRequest.BodyPublishers.noBody());
        }

        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(timeout == null ? DEFAULT_TIMEOUT : timeout)
            .build();
        HttpResponse<String> resp;
        try {
            resp = client.send(b.build(), HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new WorkbenchHttpException(
                method + " " + url + " transport error: " + e, -1, null);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new WorkbenchHttpException(
                method + " " + url + " interrupted", -1, null);
        }
        Object parsed = parseBody(resp.body());
        return new Response(resp.statusCode(), parsed);
    }

    /** Issue a JSON REST call with the default 10s timeout. */
    public static Response jsonRequest(
            String method,
            String host, int port, String path,
            String scheme, String token,
            Map<String, Object> body) {
        return jsonRequest(method, host, port, path, scheme, token, body,
                            DEFAULT_TIMEOUT);
    }

    private static Object parseBody(String raw) {
        if (raw == null || raw.isEmpty()) return null;
        try {
            return WorkbenchJson.parse(raw);
        } catch (IllegalArgumentException e) {
            // Not JSON -- return as a string so callers see what came back.
            return raw;
        }
    }
}
