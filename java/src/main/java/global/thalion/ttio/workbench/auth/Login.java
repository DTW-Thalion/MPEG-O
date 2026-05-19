/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

import global.thalion.ttio.workbench.WorkbenchJson;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.OptionalInt;
import java.util.Set;

/**
 * {@code POST /v1/auth/login} client. Returns an authenticated
 * {@link Session} on 200 OK; raises typed exceptions on the
 * documented error responses.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.auth.login_password}.</p>
 */
public final class Login {

    private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(5);

    private Login() {}

    /** Convenience overload: HTTP (no TLS), default 5s timeout. */
    public static Session loginPassword(String host, int port,
                                          String username, String password,
                                          String totp) {
        return loginPassword(host, port, username, password, totp,
                              "http", DEFAULT_TIMEOUT);
    }

    /** Full-spec overload. */
    public static Session loginPassword(String host, int port,
                                          String username, String password,
                                          String totp,
                                          String scheme,
                                          Duration timeout) {
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            throw new IllegalArgumentException(
                "scheme must be http or https; got: " + scheme);
        }
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("username", username);
        payload.put("password", password);
        payload.put("totp",     totp);
        String body = WorkbenchJson.encode(payload);

        URI url = URI.create(scheme + "://" + host + ":" + port + "/v1/auth/login");
        HttpRequest req = HttpRequest.newBuilder(url)
            .timeout(timeout)
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build();

        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(timeout)
            .build();
        HttpResponse<String> resp;
        try {
            resp = client.send(req, HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new WorkbenchAuthException("login transport error: " + e, e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new WorkbenchAuthException("login interrupted", e);
        }
        return interpret(resp);
    }

    private static Session interpret(HttpResponse<String> resp) {
        int status = resp.statusCode();
        if (status == 200) {
            return sessionFromBody(resp.body());
        }
        String message = errorMessage(resp.body());
        if (status == 401) {
            throw new InvalidCredentialsException(
                message != null ? message : "invalid credentials");
        }
        if (status == 423) {
            throw new AccountDisabledException(
                message != null ? message : "account disabled");
        }
        if (status == 429) {
            OptionalInt retryAfter = resp.headers().firstValue("Retry-After")
                .map(Login::parseRetryAfter)
                .orElse(OptionalInt.empty());
            throw new RateLimitExceededException(
                message != null ? message : "rate limit exceeded",
                retryAfter);
        }
        throw new WorkbenchAuthException(
            "login failed: HTTP " + status + ": " +
            (message != null ? message : resp.body()));
    }

    private static OptionalInt parseRetryAfter(String header) {
        try {
            return OptionalInt.of(Integer.parseInt(header.trim()));
        } catch (NumberFormatException e) {
            return OptionalInt.empty();
        }
    }

    private static String errorMessage(String body) {
        if (body == null || body.isEmpty()) return null;
        try {
            Object parsed = WorkbenchJson.parse(body);
            if (parsed instanceof Map<?, ?> m) {
                Object err = m.get("error");
                if (err instanceof String s) return s;
            }
        } catch (IllegalArgumentException ignored) {
            // body wasn't JSON; fall through and surface as raw text.
        }
        return body.trim().isEmpty() ? null : body;
    }

    @SuppressWarnings("unchecked")
    private static Session sessionFromBody(String body) {
        Object parsed;
        try {
            parsed = WorkbenchJson.parse(body);
        } catch (IllegalArgumentException e) {
            throw new WorkbenchAuthException(
                "login response not JSON: " + e.getMessage(), e);
        }
        if (!(parsed instanceof Map<?, ?> mRaw)) {
            throw new WorkbenchAuthException("login response not a JSON object");
        }
        Map<String, Object> m = (Map<String, Object>) mRaw;

        String token     = required(m, "token", String.class);
        String username  = required(m, "username", String.class);
        String userId    = required(m, "user_id", String.class);
        String sessionId = required(m, "session_id", String.class);
        Number expiresAt = required(m, "expires_at", Number.class);
        String provider  = (m.get("provider") instanceof String s) ? s : "password-totp";

        Object capRaw = m.get("capabilities");
        if (!(capRaw instanceof List<?> capList)) {
            throw new WorkbenchAuthException(
                "login response 'capabilities' must be a list");
        }
        Set<String> capabilities = new HashSet<>();
        for (Object c : capList) {
            if (!(c instanceof String s)) {
                throw new WorkbenchAuthException(
                    "login response 'capabilities' must be a string list");
            }
            capabilities.add(s);
        }

        Object projRaw = m.get("projects");
        if (!(projRaw instanceof List<?> projList)) {
            throw new WorkbenchAuthException(
                "login response 'projects' must be a list");
        }
        List<String> projects = new ArrayList<>(projList.size());
        for (Object p : projList) {
            if (!(p instanceof String s)) {
                throw new WorkbenchAuthException(
                    "login response 'projects' must be a string list");
            }
            projects.add(s);
        }

        return new Session(
            token, username, userId,
            capabilities, projects,
            expiresAt.longValue(),
            provider, sessionId);
    }

    @SuppressWarnings("unchecked")
    private static <T> T required(Map<String, Object> m, String key,
                                    Class<T> type) {
        Object v = m.get(key);
        if (v == null) {
            throw new WorkbenchAuthException(
                "login response missing required field '" + key + "'");
        }
        if (!type.isInstance(v)) {
            throw new WorkbenchAuthException(
                "login response field '" + key + "' has unexpected type " +
                v.getClass().getSimpleName());
        }
        return (T) v;
    }
}
