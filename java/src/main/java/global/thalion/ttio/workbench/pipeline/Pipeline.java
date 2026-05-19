/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.pipeline;

import global.thalion.ttio.workbench.WorkbenchJson;

import java.util.Collections;
import java.util.Map;

/**
 * A pipeline as returned by {@code GET /v1/pipelines{,/{id}}}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.pipeline.Pipeline}.</p>
 */
public record Pipeline(
        String pipelineId,
        String identifier,
        String version,
        String project,
        String owner,
        String enginePin,            // nullable
        String definition,
        Map<String, Object> inputsSchema,
        Map<String, Object> outputsSchema) {

    public Pipeline {
        inputsSchema  = inputsSchema  == null ? Map.of() : Map.copyOf(inputsSchema);
        outputsSchema = outputsSchema == null ? Map.of() : Map.copyOf(outputsSchema);
    }

    @SuppressWarnings("unchecked")
    public static Pipeline fromJson(Map<String, Object> body) {
        return new Pipeline(
            (String) body.get("pipeline_id"),
            (String) body.get("identifier"),
            (String) body.get("version"),
            (String) body.get("project"),
            (String) body.get("owner"),
            (String) body.get("engine_pin"),
            body.get("definition") instanceof String s ? s : "",
            maybeMap(body.get("inputs_schema")),
            maybeMap(body.get("outputs_schema")));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> maybeMap(Object value) {
        if (value instanceof Map<?, ?> m) return (Map<String, Object>) m;
        if (value instanceof String s && !s.isEmpty()) {
            try {
                Object parsed = WorkbenchJson.parse(s);
                if (parsed instanceof Map<?, ?> m) return (Map<String, Object>) m;
            } catch (IllegalArgumentException ignored) {
                // fall through
            }
        }
        return Collections.emptyMap();
    }
}
