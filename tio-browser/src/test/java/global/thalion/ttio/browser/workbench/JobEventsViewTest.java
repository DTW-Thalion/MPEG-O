/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.jobs.JobEvent;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class JobEventsViewTest {

    // ---- formatFrame ----

    @Test
    void formatFrameWithEventNameAndData() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("status", "running");
        data.put("pid", 12345);
        JobEvent ev = new JobEvent("job.state", data);
        String out = JobEventsView.formatFrame(ev);
        assertTrue(out.startsWith("[job.state]"), out);
        assertTrue(out.contains("status=running"), out);
        assertTrue(out.contains("pid=12345"), out);
    }

    @Test
    void formatFrameHandlesEmptyData() {
        JobEvent ev = new JobEvent("job.heartbeat", Map.of());
        assertEquals("[job.heartbeat]", JobEventsView.formatFrame(ev));
    }

    @Test
    void formatFrameHandlesNullEventName() {
        JobEvent ev = new JobEvent(null, Map.of("k", "v"));
        String out = JobEventsView.formatFrame(ev);
        assertTrue(out.startsWith("[?]"), out);
    }

    // ---- isTerminalEvent ----

    @Test
    void isTerminalEventDetectsCompletedFailedCancelled() {
        for (String s : new String[]{"completed", "failed", "cancelled"}) {
            JobEvent ev = new JobEvent("job.state", Map.of("status", s));
            assertTrue(JobEventsView.isTerminalEvent(ev),
                "expected terminal for status=" + s);
        }
    }

    @Test
    void isTerminalEventFalseForRunningOrQueued() {
        for (String s : new String[]{"queued", "starting", "running"}) {
            JobEvent ev = new JobEvent("job.state", Map.of("status", s));
            assertFalse(JobEventsView.isTerminalEvent(ev),
                "expected non-terminal for status=" + s);
        }
    }

    @Test
    void isTerminalEventFalseForNonStateEvent() {
        JobEvent ev = new JobEvent("job.heartbeat",
            Map.of("status", "completed"));
        assertFalse(JobEventsView.isTerminalEvent(ev),
            "only job.state frames signal terminal status");
    }

    @Test
    void isTerminalEventFalseForMissingStatus() {
        JobEvent ev = new JobEvent("job.state", Map.of("pid", 1));
        assertFalse(JobEventsView.isTerminalEvent(ev));
    }

    @Test
    void isTerminalEventFalseForNull() {
        assertFalse(JobEventsView.isTerminalEvent(null));
    }
}
