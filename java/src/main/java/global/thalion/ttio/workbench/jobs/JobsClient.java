/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.jobs;

import global.thalion.ttio.workbench.WorkbenchHttp;
import global.thalion.ttio.workbench.WorkbenchJson;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * Job submit + tracking surface.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.jobs.JobsClient}.</p>
 *
 * <p>SSE long-poll on {@code /v1/jobs/{id}/events} is exposed as
 * a callback-driven {@link #events(String, Consumer)} rather than
 * an async iterator -- Java has no native async-iterator support
 * before Project Loom virtual threads, and the existing TTI-O
 * Java client surfaces (WorkbenchTransportClient) are callback-
 * driven too.</p>
 */
public final class JobsClient {

    private final String host;
    private final int port;
    private final String scheme;
    private final String token;

    public JobsClient(String host, int port, String scheme, String token) {
        this.host   = host;
        this.port   = port;
        this.scheme = scheme;
        this.token  = token;
    }

    /** {@code POST /v1/jobs}. */
    @SuppressWarnings("unchecked")
    public Job submit(String pipelineId,
                       Map<String, Object> inputs,
                       Map<String, Object> params) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("pipeline_id", pipelineId);
        body.put("inputs", inputs == null ? Map.of() : inputs);
        if (params != null) body.put("params", params);
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "POST", host, port, "/v1/jobs", scheme, token, body);
        if (resp.status() != 201) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "POST /v1/jobs failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return Job.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code GET /v1/jobs[?status=X&limit=N]}. */
    @SuppressWarnings("unchecked")
    public List<Job> list(String statusFilter, Integer limit) {
        StringBuilder path = new StringBuilder("/v1/jobs");
        List<String> params = new ArrayList<>();
        if (statusFilter != null && !statusFilter.isEmpty()) {
            params.add("status=" + URLEncoder.encode(
                statusFilter, StandardCharsets.UTF_8));
        }
        if (limit != null) {
            params.add("limit=" + limit);
        }
        if (!params.isEmpty()) {
            path.append("?").append(String.join("&", params));
        }
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, path.toString(), scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET " + path + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
        Map<String, Object> body = (Map<String, Object>) resp.body();
        Object raw = body.get("jobs");
        List<Job> out = new ArrayList<>();
        if (raw instanceof List<?> l) {
            for (Object j : l) {
                if (j instanceof Map<?, ?> m) {
                    out.add(Job.fromJson((Map<String, Object>) m));
                }
            }
        }
        return out;
    }

    /** {@code GET /v1/jobs/{id}}. */
    @SuppressWarnings("unchecked")
    public Job get(String jobId) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "GET", host, port, "/v1/jobs/" + jobId, scheme, token, null);
        if (resp.status() != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET /v1/jobs/" + jobId + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
        return Job.fromJson((Map<String, Object>) resp.body());
    }

    /** {@code DELETE /v1/jobs/{id}}. 204 No Content on success;
     *  409 when already terminal. */
    public void cancel(String jobId) {
        WorkbenchHttp.Response resp = WorkbenchHttp.jsonRequest(
            "DELETE", host, port, "/v1/jobs/" + jobId,
            scheme, token, null);
        if (resp.status() != 200 && resp.status() != 204) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "DELETE /v1/jobs/" + jobId + " failed: " + resp.status(),
                resp.status(), resp.body());
        }
    }

    /**
     * Stream {@code GET /v1/jobs/{id}/events}: emit each parsed
     * {@link JobEvent} to {@code onEvent} as it arrives. Blocks
     * the calling thread until the server closes the connection
     * (v1.0 closes on terminal state). Callers wanting non-blocking
     * behaviour should run this on a worker thread.
     */
    public void events(String jobId, Consumer<JobEvent> onEvent) {
        URI uri = URI.create(
            scheme + "://" + host + ":" + port
            + "/v1/jobs/" + jobId + "/events");
        HttpURLConnection conn;
        try {
            conn = (HttpURLConnection) new URL(uri.toString()).openConnection();
            conn.setRequestMethod("GET");
            conn.setRequestProperty("Accept", "text/event-stream");
            if (token != null && !token.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + token);
            }
            conn.setReadTimeout(0);  // no per-read timeout; server controls
        } catch (IOException e) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET " + uri + " failed to open: " + e, -1, null);
        }
        int status;
        try {
            status = conn.getResponseCode();
        } catch (IOException e) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET " + uri + " no response: " + e, -1, null);
        }
        if (status != 200) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "GET " + uri + " status " + status, status, null);
        }
        try (InputStream in = conn.getInputStream();
              BufferedReader r = new BufferedReader(
                  new InputStreamReader(in, StandardCharsets.UTF_8))) {
            String currentEvent = "";
            StringBuilder data = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("event:")) {
                    currentEvent = line.substring("event:".length()).trim();
                } else if (line.startsWith("data:")) {
                    if (data.length() > 0) data.append('\n');
                    data.append(line.substring("data:".length()).trim());
                } else if (line.isEmpty()) {
                    if (!currentEvent.isEmpty() || data.length() > 0) {
                        Map<String, Object> payload = parseData(data.toString());
                        onEvent.accept(new JobEvent(currentEvent, payload));
                        currentEvent = "";
                        data.setLength(0);
                    }
                }
                // `:` comment lines are heartbeat / no-ops.
            }
        } catch (IOException e) {
            throw new WorkbenchHttp.WorkbenchHttpException(
                "SSE read error: " + e, -1, null);
        } finally {
            conn.disconnect();
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> parseData(String data) {
        if (data.isEmpty()) return Map.of();
        try {
            Object parsed = WorkbenchJson.parse(data);
            if (parsed instanceof Map<?, ?> m) return (Map<String, Object>) m;
        } catch (IllegalArgumentException ignored) {
            // malformed; surface as raw
        }
        return Map.of("_raw", data);
    }

    /** Build the {@code {"cohort_query": ...}} envelope the server
     *  recognises as a Decision-4 cohort-resolution input slot. */
    public static Map<String, Object> cohortInput(Map<String, Object> queryJson) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("cohort_query", queryJson);
        return out;
    }
}
