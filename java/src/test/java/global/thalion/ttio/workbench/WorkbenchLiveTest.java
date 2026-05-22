/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.protection.PerAUFile;
import global.thalion.ttio.protection.PostQuantumCrypto;
import global.thalion.ttio.workbench.WorkbenchHttp;
import global.thalion.ttio.workbench.auth.BootstrapAdminAuth;
import global.thalion.ttio.workbench.pqc.WorkbenchPqc;
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
import org.junit.jupiter.api.io.TempDir;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Path;
import java.util.LinkedHashMap;
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
        // Wait until the session leaves "starting" before terminating:
        // a DELETE on a not-yet-running session can race to a 409, which
        // made this test flake intermittently. Bounded so a stuck spawn
        // still fails the assertions below rather than hanging.
        long startDeadline = System.nanoTime() + (long) 15e9;
        while (System.nanoTime() < startDeadline) {
            if (!"starting".equals(sessions.get(created.sessionId()).status())) break;
            Thread.sleep(200);
        }
        try {
            boolean listed = sessions.list(null, 100).stream()
                .anyMatch(s -> created.sessionId().equals(s.sessionId()));
            assertTrue(listed, "created session should appear in list()");
        } finally {
            try {
                sessions.terminate(created.sessionId());
            } catch (WorkbenchHttp.WorkbenchHttpException e) {
                // 409 = already terminal/terminating; the poll below still
                // asserts the session reaches a terminal state.
                if (e.status() != 409) throw e;
            }
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

    // ---------------------------------------------- per-AU encrypted upload

    @Test
    void perAuEncryptedUploadRoundTrip(@TempDir Path tmp) throws Exception {
        // Java parity of the Python Phase 1 client round-trip:
        // uploadEncrypted (encrypt a copy per-AU + emit a valid .tis) ->
        // daemon stores it opaque (server #31) -> downloadDecrypted
        // (materialise + decrypt) -> channel bytes match the plaintext.
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) 0x5A);

        int nSpectra = 3, perSpectrum = 4, total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(nSpectra,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);

        String src = tmp.resolve("enc_src.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(src,
                "live enc", "ISA-LIVE-ENC",
                List.of(run), List.of(), List.of(), List.of())) { }

        String uri = "uri:tio:" + project + "-enc-"
            + UUID.randomUUID().toString().substring(0, 8);
        var result = client.uploadEncrypted(project, uri, src, key, false);

        String out = tmp.resolve("rt.tio").toString();
        Map<String, PerAUFile.DecryptedRun> rt =
            client.downloadDecrypted(result.containerUri(), key, out);

        assertArrayEquals(leBytes(mz),
            rt.get("run_0001").channels().get("mz"));
        assertArrayEquals(leBytes(intensity),
            rt.get("run_0001").channels().get("intensity"));
    }

    @Test
    void perAuEncryptedPqcUploadRoundTrip(@TempDir Path tmp) throws Exception {
        // Java parity of the Python Phase 3 PQC round-trip: a fresh per-run
        // DEK is ML-KEM-1024-wrapped into the ProtectionMetadata (no
        // caller-held key). Only the ML-KEM private key recovers it.
        // Preview-gated like the server's opt_pqc_preview; the wrong
        // private key must fail to decrypt.
        int nSpectra = 3, perSpectrum = 4, total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(nSpectra,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);

        String src = tmp.resolve("pqc_src.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(src,
                "live pqc", "ISA-LIVE-PQC",
                List.of(run), List.of(), List.of(), List.of())) { }

        PostQuantumCrypto.KeyPair kp = WorkbenchPqc.kemKeygen();
        String uri = "uri:tio:" + project + "-pqc-"
            + UUID.randomUUID().toString().substring(0, 8);

        // opt_pqc_preview gating: refuses without preview=true.
        assertThrows(WorkbenchPqc.PqcPreviewDisabledException.class,
            () -> client.uploadEncryptedPqc(
                project, uri, src, kp.publicKey(), false, false));

        var result = client.uploadEncryptedPqc(
            project, uri, src, kp.publicKey(), true, false);

        String out = tmp.resolve("pqc_rt.tio").toString();
        Map<String, PerAUFile.DecryptedRun> rt =
            client.downloadDecryptedPqc(result.containerUri(),
                                         kp.privateKey(), out, true);

        assertArrayEquals(leBytes(mz),
            rt.get("run_0001").channels().get("mz"));
        assertArrayEquals(leBytes(intensity),
            rt.get("run_0001").channels().get("intensity"));

        // Wrong ML-KEM private key cannot recover the DEK.
        PostQuantumCrypto.KeyPair wrong = WorkbenchPqc.kemKeygen();
        String badOut = tmp.resolve("pqc_bad.tio").toString();
        assertThrows(Exception.class,
            () -> client.downloadDecryptedPqc(
                result.containerUri(), wrong.privateKey(), badOut, true));
    }

    @Test
    void perAuEncryptedEnvelopeUploadRoundTrip(@TempDir Path tmp) throws Exception {
        // Java parity of the Python Phase 4 envelope round-trip: the
        // per-run DEK is wrapped under a 32-byte symmetric AES-256-GCM KEK
        // (not an ML-KEM key) into the ProtectionMetadata. Not preview-
        // gated; the wrong KEK must fail to decrypt.
        byte[] kek = new byte[32];
        java.util.Arrays.fill(kek, (byte) 0x3C);

        int nSpectra = 3, perSpectrum = 4, total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(nSpectra,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);

        String src = tmp.resolve("env_src.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(src,
                "live env", "ISA-LIVE-ENV",
                List.of(run), List.of(), List.of(), List.of())) { }

        String uri = "uri:tio:" + project + "-env-"
            + UUID.randomUUID().toString().substring(0, 8);
        var result = client.uploadEncryptedEnvelope(project, uri, src, kek, false);

        String out = tmp.resolve("env_rt.tio").toString();
        Map<String, PerAUFile.DecryptedRun> rt =
            client.downloadDecryptedEnvelope(result.containerUri(), kek, out);

        assertArrayEquals(leBytes(mz),
            rt.get("run_0001").channels().get("mz"));
        assertArrayEquals(leBytes(intensity),
            rt.get("run_0001").channels().get("intensity"));

        // Wrong KEK cannot recover the DEK.
        byte[] wrongKek = new byte[32];
        java.util.Arrays.fill(wrongKek, (byte) 0x11);
        String badOut = tmp.resolve("env_bad.tio").toString();
        assertThrows(Exception.class,
            () -> client.downloadDecryptedEnvelope(
                result.containerUri(), wrongKek, badOut));
    }

    @Test
    void multiRecipientUploadRoundTrip(@TempDir Path tmp) throws Exception {
        // FD-1 Phase B-2: one DEK wrapped for TWO recipients -- primary =
        // server symmetric KEK, additional = researcher ML-KEM-1024 (the
        // FD-1 output shape). Each party independently recovers the same
        // plaintext with its own key; the daemon holds neither.
        byte[] serverKek = new byte[32];
        java.util.Arrays.fill(serverKek, (byte) 0x2A);

        int nSpectra = 3, perSpectrum = 4, total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(nSpectra,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);

        String src = tmp.resolve("multi_src.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(src,
                "live multi", "ISA-LIVE-MULTI",
                List.of(run), List.of(), List.of(), List.of())) { }

        PostQuantumCrypto.KeyPair kp = WorkbenchPqc.kemKeygen();
        List<WorkbenchClient.EnvelopeRecipient> recipients = List.of(
            new WorkbenchClient.EnvelopeRecipient("server", serverKek, "aes-256-gcm"),
            new WorkbenchClient.EnvelopeRecipient(
                "researcher", kp.publicKey(), WorkbenchPqc.ML_KEM_1024));
        String uri = "uri:tio:" + project + "-multi-"
            + UUID.randomUUID().toString().substring(0, 8);

        // An ML-KEM recipient makes the upload preview-gated.
        assertThrows(WorkbenchPqc.PqcPreviewDisabledException.class,
            () -> client.uploadEncryptedMulti(
                project, uri, src, recipients, false, false));

        var result = client.uploadEncryptedMulti(
            project, uri, src, recipients, true, false);

        // The server unwraps the primary (recipientId "") with its KEK.
        String outS = tmp.resolve("multi_server.tio").toString();
        Map<String, PerAUFile.DecryptedRun> viaServer =
            client.downloadDecryptedMulti(
                result.containerUri(), serverKek, outS, "", false);
        // The researcher unwraps its entry with the ML-KEM private key.
        String outR = tmp.resolve("multi_researcher.tio").toString();
        Map<String, PerAUFile.DecryptedRun> viaResearcher =
            client.downloadDecryptedMulti(
                result.containerUri(), kp.privateKey(), outR, "researcher", true);

        assertArrayEquals(leBytes(mz),
            viaServer.get("run_0001").channels().get("mz"));
        assertArrayEquals(viaServer.get("run_0001").channels().get("mz"),
            viaResearcher.get("run_0001").channels().get("mz"));
        assertArrayEquals(viaServer.get("run_0001").channels().get("intensity"),
            viaResearcher.get("run_0001").channels().get("intensity"));

        // Selecting a recipient id that isn't present is rejected.
        String outX = tmp.resolve("multi_x.tio").toString();
        assertThrows(IllegalArgumentException.class,
            () -> client.downloadDecryptedMulti(
                result.containerUri(), serverKek, outX, "nobody", false));
    }

    @Test
    void perAuEncryptedHeadersUploadRoundTrip(@TempDir Path tmp) throws Exception {
        // BYOK round-trip with encryptHeaders=true: the other encrypted
        // live tests pass false, so this exercises the distinct
        // encrypted-AU-headers transport path (AU header bytes encrypted,
        // not just channel payloads).
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) 0x77);

        int nSpectra = 3, perSpectrum = 4, total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(nSpectra,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);

        String src = tmp.resolve("hdr_src.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(src,
                "live hdr", "ISA-LIVE-HDR",
                List.of(run), List.of(), List.of(), List.of())) { }

        String uri = "uri:tio:" + project + "-hdr-"
            + UUID.randomUUID().toString().substring(0, 8);
        var result = client.uploadEncrypted(project, uri, src, key, true);

        String out = tmp.resolve("hdr_rt.tio").toString();
        Map<String, PerAUFile.DecryptedRun> rt =
            client.downloadDecrypted(result.containerUri(), key, out);

        assertArrayEquals(leBytes(mz),
            rt.get("run_0001").channels().get("mz"));
        assertArrayEquals(leBytes(intensity),
            rt.get("run_0001").channels().get("intensity"));
    }

    private static byte[] leBytes(double[] a) {
        ByteBuffer b = ByteBuffer.allocate(a.length * 8)
            .order(ByteOrder.LITTLE_ENDIAN);
        for (double d : a) b.putDouble(d);
        return b.array();
    }
}
