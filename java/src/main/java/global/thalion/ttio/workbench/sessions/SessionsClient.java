/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.sessions;

import global.thalion.ttio.workbench.WorkbenchHttp;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * REST surface for interactive sessions.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.sessions.SessionsClient}.</p>
 */
public final class SessionsClient {

    private final String host;
    private final int port;
    private final String scheme;
    private final String token;

    public SessionsClient(String host, int port, String scheme, String token) {
        this.host   = host;
        this.port   = port;
        this.scheme = scheme;
        this.token  = token;
    }

    /** Builder for {@code POST /v1/sessions} requests. */
    public static final class CreateRequest {
        public String project;
        public String enginePin;
        public String image;
        public List<String> command;
        public Map<String, String> env;
        public Map<String, String> bindMounts;
        public String containerStorageRoot;  // client-side bind-mount validation hint

        public CreateRequest project(String s)         { this.project = s; return this; }
        public CreateRequest enginePin(String s)       { this.enginePin = s; return this; }
        public CreateRequest image(String s)           { this.image = s; return this; }
        public CreateRequest command(List<String> v)   { this.command = v; return this; }
        public CreateRequest env(Map<String, String> v){ this.env = v; return this; }
        public CreateRequest bindMounts(Map<String, String> v) {
            this.bindMounts = v; return this;
        }
        public CreateRequest containerStorageRoot(String s) {
            this.containerStorageRoot = s; return this;
        }
    }

    /** {@code POST /v1/sessions}. */
    @SuppressWarnings("unchecked")
    public Session create(CreateRequest req) {
        if (req.project == null || req.enginePin == null) {
            throw new IllegalArgumentException(
                "CreateRequest requires project + enginePin");
        }
        BindMountValidator.validate(req.bindMounts, req.project,
                                      req.containerStorageRoot);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("project", req.project);
        body.put("engine_pin", req.enginePin);
        if (req.image       != null) body.put("image", req.image);
        if (req.command     != null) body.put("command", req.command);
        if (req.env         != null) body.put("env", req.env);
        if (req.bindMounts  != null) body.put("bind_mounts", req.bindMounts);
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "POST", host, port, "/v1/sessions", scheme, token, body);
        if (resp.status() != 201) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "POST /v1/sessions failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return Session.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code GET /v1/sessions[?status=X&limit=N]}. */
    @SuppressWarnings("unchecked")
    public List<Session> list(String statusFilter, Integer limit) {
        StringBuilder path = new StringBuilder("/v1/sessions");
        List<String> params = new ArrayList<>();
        if (statusFilter != null) params.add("status=" + statusFilter);
        if (limit != null) params.add("limit=" + limit);
        if (!params.isEmpty()) path.append("?").append(String.join("&", params));
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, path.toString(), scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET " + path + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
        Map<String, Object> body = (Map<String, Object>) resp.body();
        Object raw = body.get("sessions");
        List<Session> out = new ArrayList<>();
        if (raw instanceof List<?> l) {
            for (Object s : l) {
                if (s instanceof Map<?, ?> m) {
                    out.add(Session.fromJson((Map<String, Object>) m));
                }
            }
        }
        return out;
    }

    /** {@code GET /v1/sessions/{id}}. */
    @SuppressWarnings("unchecked")
    public Session get(String sessionId) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, "/v1/sessions/" + sessionId,
            scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/sessions/" + sessionId + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return Session.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code DELETE /v1/sessions/{id}}. 204 No Content on success;
     *  409 when already terminal. Authorization: owner OR
     *  {@code sessions.terminate.any}. */
    public void terminate(String sessionId) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "DELETE", host, port, "/v1/sessions/" + sessionId,
            scheme, token, null);
        if (resp.status() != 200 && resp.status() != 204) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "DELETE /v1/sessions/" + sessionId + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
    }
}
