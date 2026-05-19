/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.pipeline;

import global.thalion.ttio.workbench.WorkbenchHttp;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Pipeline registry surface.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.pipeline.PipelinesClient}.</p>
 */
public final class PipelinesClient {

    private final String host;
    private final int port;
    private final String scheme;
    private final String token;

    public PipelinesClient(String host, int port, String scheme, String token) {
        this.host   = host;
        this.port   = port;
        this.scheme = scheme;
        this.token  = token;
    }

    /** {@code POST /v1/pipelines}. */
    public Pipeline register(
            String identifier,
            String version,
            String project,
            String definition,
            String enginePin,                       // nullable
            Map<String, Object> inputsSchema,       // nullable
            Map<String, Object> outputsSchema) {    // nullable
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("identifier", identifier);
        body.put("version", version);
        body.put("project", project);
        body.put("definition", definition);
        if (enginePin     != null) body.put("engine_pin",      enginePin);
        if (inputsSchema  != null) body.put("inputs_schema",   inputsSchema);
        if (outputsSchema != null) body.put("outputs_schema",  outputsSchema);
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "POST", host, port, "/v1/pipelines", scheme, token, body);
        if (resp.status() != 201) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "POST /v1/pipelines failed: " + resp.status(),
                resp.status(), resp.body());
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> respBody = (Map<String, Object>) resp.body();
        return Pipeline.fromJson(respBody);
    }

    /** {@code GET /v1/pipelines}. */
    @SuppressWarnings("unchecked")
    public List<Pipeline> list() {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, "/v1/pipelines", scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/pipelines failed: " + resp.status(),
                resp.status(), resp.body());
        }
        Map<String, Object> body = (Map<String, Object>) resp.body();
        Object raw = body.get("pipelines");
        List<Pipeline> out = new ArrayList<>();
        if (raw instanceof List<?> l) {
            for (Object p : l) {
                if (p instanceof Map<?, ?> m) {
                    out.add(Pipeline.fromJson((Map<String, Object>) m));
                }
            }
        }
        return out;
    }

    /** {@code GET /v1/pipelines/{id}}. */
    @SuppressWarnings("unchecked")
    public Pipeline get(String pipelineId) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, "/v1/pipelines/" + pipelineId,
            scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/pipelines/" + pipelineId + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return Pipeline.fromJson((Map<String, Object>) resp.body());
    }
}
