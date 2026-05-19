/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.containers;

import global.thalion.ttio.workbench.WorkbenchHttp;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * REST client for the {@code /v1/containers} endpoint.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.containers.ContainersClient}.</p>
 *
 * <p>v1.0 surface: list (paginated), get one, list layers, get
 * manifest. DELETE is server-side admin and exposed via
 * {@link #delete(String)}; v1.0 clients call it through the
 * regular session, gated on the server-side capability.</p>
 */
public final class ContainersClient {

    private final String host;
    private final int port;
    private final String scheme;
    private final String token;

    public ContainersClient(String host, int port, String scheme, String token) {
        this.host   = host;
        this.port   = port;
        this.scheme = scheme;
        this.token  = token;
    }

    /** {@code GET /v1/containers[?project=...&owner=...&limit=N&cursor=X]}. */
    @SuppressWarnings("unchecked")
    public ContainerListPage list(String project, String owner,
                                    Integer limit, String cursor) {
        StringBuilder path = new StringBuilder("/v1/containers");
        List<String> params = new ArrayList<>();
        if (project != null && !project.isEmpty()) {
            params.add("project=" + enc(project));
        }
        if (owner != null && !owner.isEmpty()) {
            params.add("owner=" + enc(owner));
        }
        if (limit != null) {
            params.add("limit=" + limit);
        }
        if (cursor != null && !cursor.isEmpty()) {
            params.add("cursor=" + enc(cursor));
        }
        if (!params.isEmpty()) {
            path.append('?').append(String.join("&", params));
        }
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, path.toString(), scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/containers failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return ContainerListPage.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code GET /v1/containers/{safe_uri}}. */
    @SuppressWarnings("unchecked")
    public ContainerDetail get(String uri) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port,
            "/v1/containers/" + encPath(uri),
            scheme, token, null);
        if (resp.status() == 404) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "container not found: " + uri, 404, resp.body());
        }
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/containers/" + uri + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return ContainerDetail.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code GET /v1/containers/{safe_uri}/layers}. */
    @SuppressWarnings("unchecked")
    public List<ContainerLayer> layers(String uri) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port,
            "/v1/containers/" + encPath(uri) + "/layers",
            scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/containers/" + uri + "/layers failed: " + resp.status(),
                resp.status(), resp.body());
        }
        Map<String, Object> body = (Map<String, Object>) resp.body();
        List<Map<String, Object>> raw = (List<Map<String, Object>>)
            body.getOrDefault("layers", List.of());
        return raw.stream().map(ContainerLayer::fromJson).toList();
    }

    /** {@code GET /v1/containers/{safe_uri}/manifest}. */
    @SuppressWarnings("unchecked")
    public ContainerManifest manifest(String uri) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port,
            "/v1/containers/" + encPath(uri) + "/manifest",
            scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/containers/" + uri + "/manifest failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return ContainerManifest.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code DELETE /v1/containers/{safe_uri}}.
     *
     *  <p>v1.0: gated on either {@code containers.delete.any} or
     *  {@code containers.delete.own_uploads}. Non-idempotent;
     *  subsequent reads of the URI return 404.</p>
     */
    public void delete(String uri) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "DELETE", host, port,
            "/v1/containers/" + encPath(uri),
            scheme, token, null);
        if (resp.status() != 204 && resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "DELETE /v1/containers/" + uri + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
    }

    /** URL-encode a query value (regular form-encoding rules). */
    static String enc(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8);
    }

    /** Encode a path segment. The server's {@code safe_uri} is the
     *  URI's opaque part with {@code :} and {@code /} percent-encoded;
     *  {@link URLEncoder} flips space-to-plus which is incorrect for
     *  path segments. */
    static String encPath(String s) {
        // RFC 3986 unreserved + a small set the server accepts.
        return enc(s).replace("+", "%20");
    }
}
