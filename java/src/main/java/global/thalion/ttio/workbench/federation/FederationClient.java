/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.federation;

import global.thalion.ttio.workbench.WorkbenchHttp;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * REST client for the {@code /v1/federation} endpoint.
 *
 * <p>Federation is a v1.1+ server feature (spec §12.3). The v1.0
 * server is single-node and does <b>not</b> expose
 * {@code /v1/federation/peers}. This client degrades gracefully:
 * {@link #peers()} returns an empty list on a 404 instead of throwing,
 * so callers can treat a v1.0 server as a single-node federation of
 * one.</p>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.federation.FederationClient}.</p>
 */
public final class FederationClient {

    private final String host;
    private final int port;
    private final String scheme;
    private final String token;

    public FederationClient(String host, int port, String scheme, String token) {
        this.host   = host;
        this.port   = port;
        this.scheme = scheme;
        this.token  = token;
    }

    /** A federation peer node from {@code GET /v1/federation/peers}. */
    public record Peer(String peerId, String url, String status) {
        static Peer fromJson(Map<String, Object> m) {
            Object id = m.get("peer_id");
            if (id == null) id = m.get("id");
            Object url = m.get("url");
            Object status = m.get("status");
            return new Peer(
                id == null ? "" : id.toString(),
                url == null ? "" : url.toString(),
                status == null ? "unknown" : status.toString());
        }
    }

    /** {@code GET /v1/federation/peers}. Returns an empty list when the
     *  server does not expose the endpoint (HTTP 404 -- a v1.0
     *  single-node server). Any other non-2xx status throws. */
    @SuppressWarnings("unchecked")
    public List<Peer> peers() {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, "/v1/federation/peers", scheme, token, null);
        if (resp.status() == 404) {
            return List.of();  // v1.0 single-node: federation not exposed
        }
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/federation/peers failed: " + resp.status(),
                resp.status(), resp.body());
        }
        Object body = resp.body();
        List<Object> rows = List.of();
        if (body instanceof Map<?, ?> m) {
            Object p = ((Map<String, Object>) m).get("peers");
            if (p instanceof List<?> l) rows = (List<Object>) l;
        } else if (body instanceof List<?> l) {
            rows = (List<Object>) l;
        }
        List<Peer> out = new ArrayList<>(rows.size());
        for (Object r : rows) {
            if (r instanceof Map<?, ?> rm) {
                out.add(Peer.fromJson((Map<String, Object>) rm));
            }
        }
        return out;
    }

    /** True iff the server reports at least one federation peer. A v1.0
     *  single-node server reports none. */
    public boolean isFederated() {
        return !peers().isEmpty();
    }
}
