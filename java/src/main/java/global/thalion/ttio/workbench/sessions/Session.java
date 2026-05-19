/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.sessions;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * A session as returned by {@code GET /v1/sessions{,/{id}}}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.sessions.Session}. State machine:
 * starting -> running -> terminating -> terminated | failed.</p>
 */
public record Session(
        String sessionId,
        String status,
        String project,
        String owner,
        String engineIdentifier,
        long startedAt,
        // Runtime fields (populated once the session leaves `starting`):
        Integer hostPort,
        Integer pid,
        String containerId,
        String workingDir,
        Long readyAt,
        Long lastSeenAt,
        Long terminatedAt,
        Integer exitCode,
        String errorMessage,
        // Spec fields the operator supplied:
        String image,
        List<String> command,
        Map<String, String> env,
        Map<String, String> bindMounts) {

    public static final Set<String> TERMINAL_STATUSES = Set.of("terminated", "failed");
    public static final Set<String> ALL_STATUSES = Set.of(
        "starting", "running", "terminating", "terminated", "failed");

    public Session {
        command    = command    == null ? List.of() : List.copyOf(command);
        env        = env        == null ? Map.of()  : Map.copyOf(env);
        bindMounts = bindMounts == null ? Map.of()  : Map.copyOf(bindMounts);
    }

    public boolean isTerminal() {
        return TERMINAL_STATUSES.contains(status);
    }

    public boolean isAttachable() {
        return "running".equals(status);
    }

    @SuppressWarnings("unchecked")
    public static Session fromJson(Map<String, Object> body) {
        return new Session(
            (String) body.get("session_id"),
            (String) body.get("status"),
            (String) body.get("project"),
            (String) body.get("owner"),
            (String) body.get("engine_identifier"),
            longField(body.get("started_at")),
            optInt(body.get("host_port")),
            optInt(body.get("pid")),
            (String) body.get("container_id"),
            (String) body.get("working_dir"),
            optLong(body.get("ready_at")),
            optLong(body.get("last_seen_at")),
            optLong(body.get("terminated_at")),
            optInt(body.get("exit_code")),
            (String) body.get("error_message"),
            (String) body.get("image"),
            (List<String>) body.getOrDefault("command", List.of()),
            (Map<String, String>) body.getOrDefault("env", Map.of()),
            (Map<String, String>) body.getOrDefault("bind_mounts", Map.of()));
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
