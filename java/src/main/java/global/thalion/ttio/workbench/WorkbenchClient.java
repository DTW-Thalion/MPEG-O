/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.auth.Session;
import global.thalion.ttio.workbench.cohort.CohortQuery;
import global.thalion.ttio.workbench.cohort.CohortResult;
import global.thalion.ttio.workbench.containers.ContainersClient;
import global.thalion.ttio.workbench.jobs.JobsClient;
import global.thalion.ttio.workbench.pipeline.PipelinesClient;
import global.thalion.ttio.workbench.sessions.SessionProxyAttach;
import global.thalion.ttio.workbench.sessions.SessionsClient;
import global.thalion.ttio.workbench.transport.TransferProgress;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.OutputMode;
import global.thalion.ttio.workbench.transport.WorkbenchTransportClient;

import java.net.URI;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;

/**
 * Top-level SDK entry for the workbench client.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.client.WorkbenchClient}. The Java side
 * targets {@code tio-browser} as its primary consumer (per
 * workbench-client workplan Decision 1: CLI stays Python; Java
 * is the GUI SDK). The same shape is exposed so non-tio-browser
 * Java consumers can drop in too.</p>
 *
 * <p>Usage mirroring the Python {@code ttio.connect(...)} sample:</p>
 * <pre>{@code
 * AuthProvider auth = new PasswordTotpAuth("alice", "pw", "012345");
 * try (WorkbenchClient client = WorkbenchClient.connect(
 *         "wss://biobank.example.com:8443/transport", auth)) {
 *     WorkbenchTransportClient.UploadResult result =
 *         client.transportClient().upload("alpha", "uri:tio:demo", tisBytes);
 *     System.out.println(result.containerUri());
 * }
 * }</pre>
 *
 * <p>Closing the client is a no-op in v1.0 (the workbench server
 * doesn't hold long-lived state for the bearer); kept as
 * {@link AutoCloseable} so future credential-revocation paths
 * can hook in without breaking callers.</p>
 */
public final class WorkbenchClient implements AutoCloseable {

    /** Resolved server endpoint. */
    public record Endpoint(String host, int port,
                            String wsScheme, String httpScheme) {}

    private final Endpoint endpoint;
    private final AuthProvider auth;
    private volatile Session session;

    private WorkbenchClient(Endpoint endpoint, AuthProvider auth, Session session) {
        this.endpoint = endpoint;
        this.auth = auth;
        this.session = session;
    }

    /** Resolve the endpoint, authenticate, return a client. */
    public static WorkbenchClient connect(String url, AuthProvider auth) {
        if (auth == null) {
            throw new IllegalArgumentException("connect() requires `auth`");
        }
        Endpoint ep = parseUrl(url);
        Session session = auth.authenticate(ep.host, ep.port, ep.httpScheme);
        return new WorkbenchClient(ep, auth, session);
    }

    /** Re-authenticate using the stored provider. Use when
     *  {@link Session#isExpired()} flips true mid-script. */
    public void reauth() {
        this.session = auth.authenticate(endpoint.host, endpoint.port,
                                           endpoint.httpScheme);
    }

    public Session  session()    { return session; }
    public Endpoint endpoint()   { return endpoint; }
    public String   host()       { return endpoint.host; }
    public int      port()       { return endpoint.port; }
    public String   wsScheme()   { return endpoint.wsScheme; }
    public String   httpScheme() { return endpoint.httpScheme; }

    /** Build a {@link WorkbenchTransportClient} bound to this
     *  session + endpoint. */
    public WorkbenchTransportClient transportClient() {
        return WorkbenchTransportClient.builder(endpoint.host, endpoint.port)
            .session(session)
            .useTls("wss".equals(endpoint.wsScheme))
            .build();
    }

    /** Convenience: one-shot upload via the transport client. */
    public WorkbenchTransportClient.UploadResult upload(
            String project, String containerUri, byte[] payload) {
        return transportClient().upload(project, containerUri, payload);
    }

    /** Convenience: one-shot upload reporting byte progress.
     *  {@code progress} receives {@code (bytesSent, payload.length)}
     *  per chunk — a determinate fraction. */
    public WorkbenchTransportClient.UploadResult upload(
            String project, String containerUri, byte[] payload,
            TransferProgress progress) {
        return transportClient().upload(project, containerUri, payload,
                                          null, progress);
    }

    /** Convenience: one-shot download via the transport client. */
    public WorkbenchTransportClient.DownloadResult download(
            String containerUri) {
        return transportClient().download(containerUri);
    }

    /** Convenience: one-shot download reporting byte progress. The
     *  server streams without a known total, so {@code progress}
     *  receives {@code (bytesReceived, TransferProgress.UNKNOWN_TOTAL)}. */
    public WorkbenchTransportClient.DownloadResult download(
            String containerUri, TransferProgress progress) {
        return transportClient().download(containerUri, null,
                                            OutputMode.BINARY, 0, progress);
    }

    /** Convenience: filtered download. */
    public WorkbenchTransportClient.DownloadResult download(
            String containerUri,
            Map<String, Object> filter,
            OutputMode outputMode,
            int maxAu) {
        return transportClient().download(containerUri, filter,
                                            outputMode, maxAu);
    }

    /** Convenience: filtered download reporting byte progress. */
    public WorkbenchTransportClient.DownloadResult download(
            String containerUri,
            Map<String, Object> filter,
            OutputMode outputMode,
            int maxAu,
            TransferProgress progress) {
        return transportClient().download(containerUri, filter,
                                            outputMode, maxAu, progress);
    }

    // ----------------------------------------------- W3 surfaces

    /** {@code POST /v1/cohorts/query}. */
    @SuppressWarnings("unchecked")
    public CohortResult query(CohortQuery query) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "POST", endpoint.host, endpoint.port,
            "/v1/cohorts/query",
            endpoint.httpScheme, session.token(), query.toJson());
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "POST /v1/cohorts/query failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return CohortResult.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code POST /v1/cohorts/preview-count}. */
    @SuppressWarnings("unchecked")
    public long previewCount(CohortQuery query) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "POST", endpoint.host, endpoint.port,
            "/v1/cohorts/preview-count",
            endpoint.httpScheme, session.token(), query.toJson());
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "POST /v1/cohorts/preview-count failed: " + resp.status(),
                resp.status(), resp.body());
        }
        Object count = ((Map<String, Object>) resp.body()).get("count");
        return count instanceof Number n ? n.longValue() : 0L;
    }

    /** Build a {@link ContainersClient} bound to this session. */
    public ContainersClient containers() {
        return new ContainersClient(
            endpoint.host, endpoint.port,
            endpoint.httpScheme, session.token());
    }

    /** Build a {@link PipelinesClient} bound to this session. */
    public PipelinesClient pipelines() {
        return new PipelinesClient(
            endpoint.host, endpoint.port,
            endpoint.httpScheme, session.token());
    }

    /** Build a {@link JobsClient} bound to this session. */
    public JobsClient jobs() {
        return new JobsClient(
            endpoint.host, endpoint.port,
            endpoint.httpScheme, session.token());
    }

    // ----------------------------------------------- W4 surfaces

    /** Build a {@link SessionsClient} bound to this session. */
    public SessionsClient sessions() {
        return new SessionsClient(
            endpoint.host, endpoint.port,
            endpoint.httpScheme, session.token());
    }

    /** Build a {@link SessionProxyAttach} bound to this session +
     *  endpoint. Caller drives the WS lifecycle. */
    public SessionProxyAttach sessionProxy(String sessionId, String path) {
        return SessionProxyAttach.builder()
            .host(endpoint.host).port(endpoint.port)
            .scheme(endpoint.wsScheme)
            .sessionId(sessionId)
            .token(session.token())
            .path(path == null ? "/" : path)
            .build();
    }

    private static UnsupportedOperationException notYetImplemented(
            String symbol, String milestone) {
        return new UnsupportedOperationException(
            symbol + " is a " + milestone + " feature; the v1.0 "
            + "workbench client (W1 + W2) ships auth + transport "
            + "+ SDK foundation. See "
            + "docs/workbench-client-workplan.md for the milestone plan.");
    }

    // ----------------------------------------------- AutoCloseable

    @Override
    public void close() {
        // v1.0: no-op. The bearer token has a server-side TTL; no
        // explicit logout is required. Reserved for v1.1 OIDC where
        // refresh-token revocation may need a network round-trip.
    }

    // ----------------------------------------------- URL parsing

    /** Parse the user-facing connect URL into host + port + schemes.
     *
     *  <p>Cross-language equivalent: Python
     *  {@code ttio.workbench.client._parse_url}. Accepts (in order
     *  of typical use):</p>
     *  <ul>
     *    <li>{@code wss://host:port/transport} -- spec section 8.3 shape</li>
     *    <li>{@code ws://host:port/transport} -- dev / loopback</li>
     *    <li>{@code https://host:port} -- REST-only convenience</li>
     *    <li>{@code http://host:port}</li>
     *    <li>{@code host:port} -- bare; defaults to ws / http and port 8443</li>
     *  </ul>
     */
    public static Endpoint parseUrl(String url) {
        Objects.requireNonNull(url, "url");
        String raw = url.contains("://") ? url : "ws://" + url;
        URI u;
        try {
            u = URI.create(raw);
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException(
                "could not parse URL: " + url, e);
        }
        String scheme = u.getScheme() == null
            ? null : u.getScheme().toLowerCase(Locale.ROOT);
        String wsScheme;
        String httpScheme;
        if ("ws".equals(scheme) || "wss".equals(scheme)) {
            wsScheme = scheme;
            httpScheme = "wss".equals(scheme) ? "https" : "http";
        } else if ("http".equals(scheme) || "https".equals(scheme)) {
            httpScheme = scheme;
            wsScheme = "https".equals(scheme) ? "wss" : "ws";
        } else {
            throw new IllegalArgumentException(
                "unsupported scheme " + scheme
                + "; expected one of ws / wss / http / https");
        }
        String host = u.getHost();
        if (host == null || host.isEmpty()) {
            throw new IllegalArgumentException("URL missing host: " + url);
        }
        int port = u.getPort();
        if (port < 0) port = 8443;  // workbench-server default
        return new Endpoint(host, port, wsScheme, httpScheme);
    }
}
