/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.jobs;

import java.util.Map;

/**
 * One SSE frame from {@code GET /v1/jobs/{id}/events}. v1.0
 * emits {@code event: job.state} only; future server versions
 * may add {@code job.heartbeat} / {@code job.log_line}.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.jobs.JobEvent}.</p>
 */
public record JobEvent(String event, Map<String, Object> data) {

    public JobEvent {
        data = data == null ? Map.of() : Map.copyOf(data);
    }

    /** Convenience: is this a state-transition event? */
    public boolean isStateEvent() {
        return "job.state".equals(event);
    }
}
