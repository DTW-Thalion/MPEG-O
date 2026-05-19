/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.jobs;

import java.util.Map;
import java.util.Set;

/**
 * A pipeline job as returned by {@code GET /v1/jobs{,/{id}}}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.jobs.Job}. State machine:
 * queued -> starting -> running -> completed
 *                                  failed
 *                                  cancelled.</p>
 */
public record Job(
        String jobId,
        String pipelineId,
        String status,
        String project,
        String owner,
        long queuedAt,
        Long startedAt,            // nullable
        Long completedAt,
        String workingDir,
        String engineIdentifier,
        Integer pid,
        Integer exitCode,
        String errorMessage,
        Map<String, Object> inputs,
        Map<String, Object> params,
        Map<String, Object> inputsQuery) {

    public static final Set<String> TERMINAL_STATUSES =
        Set.of("completed", "failed", "cancelled");

    public Job {
        inputs       = inputs       == null ? Map.of() : Map.copyOf(inputs);
        params       = params       == null ? Map.of() : Map.copyOf(params);
        inputsQuery  = inputsQuery  == null ? Map.of() : Map.copyOf(inputsQuery);
    }

    public boolean isTerminal() {
        return TERMINAL_STATUSES.contains(status);
    }

    @SuppressWarnings("unchecked")
    public static Job fromJson(Map<String, Object> body) {
        return new Job(
            (String) body.get("job_id"),
            (String) body.get("pipeline_id"),
            (String) body.get("status"),
            (String) body.get("project"),
            (String) body.get("owner"),
            longField(body.get("queued_at")),
            optLong(body.get("started_at")),
            optLong(body.get("completed_at")),
            (String) body.get("working_dir"),
            (String) body.get("engine_identifier"),
            optInt(body.get("pid")),
            optInt(body.get("exit_code")),
            (String) body.get("error_message"),
            (Map<String, Object>) body.getOrDefault("inputs", Map.of()),
            (Map<String, Object>) body.getOrDefault("params", Map.of()),
            (Map<String, Object>) body.getOrDefault("inputs_query", Map.of()));
    }

    private static long longField(Object v) {
        if (v instanceof Number n) return n.longValue();
        return 0L;
    }

    private static Long optLong(Object v) {
        if (v instanceof Number n) return n.longValue();
        return null;
    }

    private static Integer optInt(Object v) {
        if (v instanceof Number n) return n.intValue();
        return null;
    }
}
