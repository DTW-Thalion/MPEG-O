/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.auth.BootstrapAdminAuth;
import global.thalion.ttio.workbench.cohort.CohortPredicate;
import global.thalion.ttio.workbench.cohort.CohortQuery;
import global.thalion.ttio.workbench.containers.ContainerListPage;
import global.thalion.ttio.workbench.jobs.Job;
import global.thalion.ttio.workbench.jobs.JobEvent;
import global.thalion.ttio.workbench.pipeline.Pipeline;
import global.thalion.ttio.workbench.sessions.Session;
import global.thalion.ttio.workbench.sessions.SessionsClient;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Live-daemon end-to-end test for the JAVA workbench client SDK,
 * the parity counterpart to the Python
 * {@code python/tests/integration/test_workbench_live.py}.
 *
 * <p>The Java REST surface was previously only byte-equivalence
 * tested; the live smoke (TTI-O PR #109) drove the Python client
 * only. That gap hid two real Java-side bugs (the HttpClient
 * HTTP/2 default and the LoginDialog bound-button crash) until the
 * win-x64 GUI was run by hand. This test runs the Java client
 * (connect -> containers -> cohort -> pipelines -> jobs ->
 * sessions) against a real daemon so the Java path has the same
 * live coverage as Python.</p>
 *
 * <p>GATING: the whole class is disabled unless
 * {@code TTIO_WORKBENCH_URL} is set, so the normal {@code mvn
 * verify} unit run skips it. The {@code workbench-live} workflow
 * (and {@code scripts/workbench-live-smoke.sh}) sets:</p>
 * <pre>
 *   TTIO_WORKBENCH_URL       ws://127.0.0.1:&lt;port&gt;/transport
 *   TTIO_WORKBENCH_STAGING   &lt;staging-root with bootstrap-credentials.json&gt;
 *   TTIO_WORKBENCH_PROJECT   project the bootstrap admin belongs to (default adni)
 * </pre>
 */
@EnabledIfEnvironmentVariable(named = "TTIO_WORKBENCH_URL", matches = ".+")
class WorkbenchLiveTest {

    private static String url;
    private static String project;
    private static WorkbenchClient client;

    @BeforeAll
    static void connect() {
        url = System.getenv("TTIO_WORKBENCH_URL");
        String staging = System.getenv("TTIO_WORKBENCH_STAGING");
        project = System.getenv().getOrDefault("TTIO_WORKBENCH_PROJECT", "adni");
        assertNotNull(staging, "TTIO_WORKBENCH_STAGING must be set");
        client = WorkbenchClient.connect(url, new BootstrapAdminAuth(staging));
    }

    @Test
    void connectAsBootstrapAdmin() {
        assertEquals("admin", client.session().username());
        assertTrue(client.session().token().startsWith("ttiowbs_"));
    }

    @Test
    void containersListRoundTrips() {
        ContainerListPage page = client.containers().list(project, null, null, null);
        assertNotNull(page.containers());  // may be empty on a fresh daemon
    }

    @Test
    void cohortPreviewCountRoundTrips() {
        // Server PR #29 registered TTIOWBCohortsHandler; the
        // endpoint is reachable over HTTP as of that merge.
        CohortQuery query = CohortQuery.builder()
            .select("containers")
            .predicate(CohortPredicate.container("project", "eq", project))
            .limit(100)
            .build();
        long count = client.previewCount(query);
        assertTrue(count >= 0);
    }

    @Test
    void pipelineRegisterThenListedAndJobRunsToCompletion() throws Exception {
        Pipeline pl = client.pipelines().register(
            "live-smoke-echo-" + UUID.randomUUID().toString().substring(0, 8),
            "1.0.0", project,
            "echo live-smoke-output && sleep 0.1",
            "shell", Map.of(), Map.of());
        assertNotNull(pl.pipelineId());

        boolean listed = client.pipelines().list().stream()
            .anyMatch(p -> pl.pipelineId().equals(p.pipelineId()));
        assertTrue(listed, "registered pipeline should appear in list()");

        Job job = client.jobs().submit(pl.pipelineId(), Map.of(), Map.of());
        assertNotNull(job.jobId());

        Job last = job;
        long deadline = System.nanoTime() + (long) 30e9;
        while (System.nanoTime() < deadline) {
            last = client.jobs().get(job.jobId());
            if (last.isTerminal()) break;
            Thread.sleep(200);
        }
        assertTrue(last.isTerminal(),
            "job never terminated; last status=" + last.status());
        assertEquals("completed", last.status(),
            "unexpected terminal status: " + last.status());
    }

    @Test
    void jobEventsStreamReachesTerminal() throws Exception {
        Pipeline pl = client.pipelines().register(
            "live-smoke-events-" + UUID.randomUUID().toString().substring(0, 8),
            "1.0.0", project,
            "echo evt && sleep 0.1",
            "shell", Map.of(), Map.of());
        Job job = client.jobs().submit(pl.pipelineId(), Map.of(), Map.of());

        List<JobEvent> events = new CopyOnWriteArrayList<>();
        ExecutorService ex = Executors.newSingleThreadExecutor();
        ex.submit(() -> client.jobs().events(job.jobId(), events::add));
        ex.shutdown();
        assertTrue(ex.awaitTermination(30, TimeUnit.SECONDS),
            "SSE stream did not close within 30s");

        assertFalse(events.isEmpty(), "no SSE frames received");
        boolean sawCompleted = events.stream()
            .filter(JobEvent::isStateEvent)
            .anyMatch(e -> "completed".equals(e.data().get("status")));
        assertTrue(sawCompleted,
            "terminal 'completed' state not seen in SSE stream");
    }

    @Test
    void jobCancel() throws Exception {
        Pipeline slow = client.pipelines().register(
            "live-smoke-slow-" + UUID.randomUUID().toString().substring(0, 8),
            "1.0.0", project, "sleep 60", "shell", Map.of(), Map.of());
        Job job = client.jobs().submit(slow.pipelineId(), Map.of(), Map.of());

        // Wait until it leaves the queue, then cancel.
        long d1 = System.nanoTime() + (long) 15e9;
        while (System.nanoTime() < d1) {
            String s = client.jobs().get(job.jobId()).status();
            if ("starting".equals(s) || "running".equals(s) || "queued".equals(s)) break;
            Thread.sleep(200);
        }
        client.jobs().cancel(job.jobId());

        Job last = null;
        long d2 = System.nanoTime() + (long) 15e9;
        while (System.nanoTime() < d2) {
            last = client.jobs().get(job.jobId());
            if (last.isTerminal()) break;
            Thread.sleep(200);
        }
        assertNotNull(last);
        assertEquals("cancelled", last.status(),
            "expected cancelled; got " + last.status());
    }

    @Test
    void sessionCreateListTerminate() throws Exception {
        SessionsClient sessions = client.sessions();
        Session created = sessions.create(new SessionsClient.CreateRequest()
            .project(project)
            .enginePin("shell")
            .command(List.of("/bin/sh", "-c", "sleep 60")));
        assertNotNull(created.sessionId());
        try {
            boolean listed = sessions.list(null, 100).stream()
                .anyMatch(s -> created.sessionId().equals(s.sessionId()));
            assertTrue(listed, "created session should appear in list()");
        } finally {
            sessions.terminate(created.sessionId());
        }
        Session last = null;
        long deadline = System.nanoTime() + (long) 15e9;
        while (System.nanoTime() < deadline) {
            last = sessions.get(created.sessionId());
            if (last.isTerminal()) break;
            Thread.sleep(200);
        }
        assertNotNull(last);
        assertTrue(last.isTerminal(),
            "session never terminated; status=" + last.status());
    }
}
