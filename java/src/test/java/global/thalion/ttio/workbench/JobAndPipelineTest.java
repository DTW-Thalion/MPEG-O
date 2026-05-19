/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.jobs.Job;
import global.thalion.ttio.workbench.jobs.JobEvent;
import global.thalion.ttio.workbench.jobs.JobsClient;
import global.thalion.ttio.workbench.pipeline.Pipeline;
import global.thalion.ttio.workbench.pipeline.PipelinesClient;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the W3 Job + Pipeline records + clients.
 * Pure-data tests; the daemon-required cohort/pipeline/jobs
 * client methods are excluded from JaCoCo coverage and unit-
 * tested only at the record + constructor level.
 */
class JobAndPipelineTest {

    // ---------------- Job

    @Test
    void jobFromJsonMinimal() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("job_id",      "01HJOB");
        body.put("pipeline_id", "01HPL");
        body.put("status",      "queued");
        body.put("project",     "alpha");
        body.put("owner",       "alice");
        body.put("queued_at",   1700000000L);
        Job j = Job.fromJson(body);
        assertEquals("01HJOB", j.jobId());
        assertFalse(j.isTerminal());
    }

    @Test
    void jobFromJsonFull() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("job_id",            "01HJOB");
        body.put("pipeline_id",       "01HPL");
        body.put("status",            "completed");
        body.put("project",           "alpha");
        body.put("owner",             "alice");
        body.put("queued_at",         1700000000L);
        body.put("started_at",        1700000010L);
        body.put("completed_at",      1700000100L);
        body.put("working_dir",       "/tmp/work");
        body.put("engine_identifier", "shell");
        body.put("pid",               12345);
        body.put("exit_code",         0);
        body.put("inputs",            Map.of("raw_reads", "uri:tio:r1"));
        body.put("params",            Map.of("threads", 4));
        Job j = Job.fromJson(body);
        assertTrue(j.isTerminal());
        assertEquals("shell", j.engineIdentifier());
        assertEquals(12345, j.pid());
        assertEquals(0, j.exitCode());
    }

    @Test
    void jobTerminalStatuses() {
        for (String s : Job.TERMINAL_STATUSES) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("job_id", "j"); body.put("pipeline_id", "p");
            body.put("status", s);   body.put("project", "x");
            body.put("owner", "y");  body.put("queued_at", 0L);
            assertTrue(Job.fromJson(body).isTerminal(),
                "expected terminal: " + s);
        }
    }

    @Test
    void jobNonTerminalStatuses() {
        for (String s : new String[]{"queued", "starting", "running"}) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("job_id", "j"); body.put("pipeline_id", "p");
            body.put("status", s);   body.put("project", "x");
            body.put("owner", "y");  body.put("queued_at", 0L);
            assertFalse(Job.fromJson(body).isTerminal(),
                "expected non-terminal: " + s);
        }
    }

    // ---------------- JobEvent

    @Test
    void jobEventConstruction() {
        JobEvent ev = new JobEvent("job.state", Map.of("status", "running"));
        assertTrue(ev.isStateEvent());
        assertEquals("running", ev.data().get("status"));
    }

    @Test
    void jobEventEmpty() {
        JobEvent ev = new JobEvent("", Map.of());
        assertFalse(ev.isStateEvent());
    }

    // ---------------- JobsClient construction

    @Test
    void jobsClientConstruction() {
        JobsClient c = new JobsClient("localhost", 8443, "http", "ttiowbs_abc");
        // Just verify it constructs without throwing -- the daemon-
        // required methods are excluded from coverage.
        assertNotNull(c);
    }

    // ---------------- Pipeline

    @Test
    void pipelineFromJsonFull() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("pipeline_id",    "01HPL");
        body.put("identifier",     "rnaseq");
        body.put("version",        "1.0.0");
        body.put("project",        "alpha");
        body.put("owner",          "alice");
        body.put("engine_pin",     "nextflow");
        body.put("definition",     "process { ... }");
        body.put("inputs_schema",  Map.of("reads", Map.of("type", "fastq")));
        body.put("outputs_schema", Map.of());
        Pipeline p = Pipeline.fromJson(body);
        assertEquals("01HPL", p.pipelineId());
        assertEquals("nextflow", p.enginePin());
        assertEquals("fastq",
            ((Map<?, ?>) p.inputsSchema().get("reads")).get("type"));
    }

    @Test
    void pipelineSchemaAsStringRoundTrips() {
        // Legacy server paths emit schema as TEXT -- tolerate.
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("pipeline_id", "01HPL");
        body.put("identifier",  "rnaseq");
        body.put("version",     "1.0.0");
        body.put("project",     "alpha");
        body.put("owner",       "alice");
        body.put("inputs_schema",  "{\"reads\":{\"type\":\"fastq\"}}");
        body.put("outputs_schema", "{}");
        Pipeline p = Pipeline.fromJson(body);
        assertEquals("fastq",
            ((Map<?, ?>) p.inputsSchema().get("reads")).get("type"));
        assertTrue(p.outputsSchema().isEmpty());
    }

    @Test
    void pipelinesClientConstruction() {
        PipelinesClient c = new PipelinesClient(
            "localhost", 8443, "http", "ttiowbs_abc");
        assertNotNull(c);
    }
}
