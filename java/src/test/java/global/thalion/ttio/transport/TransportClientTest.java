/*
 * TTI-O Java Implementation — v0.10 M68.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.10 M68: Java client against the Python reference server.
 *
 * <p>The Python server is spawned as a subprocess via
 * {@code python -m ttio.tools.transport_server_cli}. These tests
 * are skipped when {@code python3} or the {@code ttio} package is
 * not available on PATH.</p>
 */
class TransportClientTest {

    private static SpectralDataset buildFixture(Path dir) {
        int n = 5;
        int p = 3;
        int total = n * p;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = 100.0 * (i + 1);
        }
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = i * p;
            lengths[i] = p;
        }
        double[] rts = {1.0, 2.0, 3.0, 4.0, 5.0};
        int[] msLevels = {1, 2, 1, 2, 1};
        int[] pols = {1, 1, 1, 1, 1};
        double[] pmzs = {0.0, 510.0, 0.0, 530.0, 0.0};
        int[] pcs = {0, 2, 0, 2, 0};
        double[] bpis = new double[n];
        for (int i = 0; i < n; i++) {
            double best = 0;
            for (int k = 0; k < p; k++) best = Math.max(best, intensity[i * p + k]);
            bpis[i] = best;
        }
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        InstrumentConfig cfg = new InstrumentConfig("", "", "", "", "", "");
        AcquisitionRun run = new AcquisitionRun("run_0001",
                Enums.AcquisitionMode.MS1_DDA, idx, cfg, channels,
                List.of(), List.of(), "", 0.0);
        Path ttio = dir.resolve("src.tio");
        return SpectralDataset.create(ttio.toString(),
                "M68 server fixture", "ISA-M68-TEST",
                List.of(run), List.of(), List.of(), List.of());
    }

    /** Handle to a spawned Python server subprocess. */
    private record ServerHandle(Process process, int port) implements AutoCloseable {
        @Override public void close() {
            process.destroy();
            try { process.waitFor(2, TimeUnit.SECONDS); } catch (InterruptedException ignored) {}
            if (process.isAlive()) process.destroyForcibly();
        }
        String url() { return "ws://127.0.0.1:" + port; }
    }

    private static ServerHandle startPythonServer(Path ttioPath) throws IOException {
        // Use the venv's python if available, otherwise system python3.
        Path venvPython = Path.of(System.getProperty("user.home"),
                "MPEG-O", "python", ".venv", "bin", "python");
        String pythonBin = Files.isExecutable(venvPython)
                ? venvPython.toString() : "python3";
        ProcessBuilder pb = new ProcessBuilder(
                pythonBin, "-m", "ttio.tools.transport_server_cli",
                ttioPath.toString(), "--port", "0"
        ).redirectErrorStream(true);
        Process proc = pb.start();
        BufferedReader r = new BufferedReader(
                new InputStreamReader(proc.getInputStream(), StandardCharsets.UTF_8));
        // Read lines until we see PORT=<n>; anything else is warmup noise.
        long deadline = System.currentTimeMillis() + 10_000;
        String line;
        while (System.currentTimeMillis() < deadline) {
            line = r.readLine();
            if (line == null) break;
            if (line.startsWith("PORT=")) {
                int port = Integer.parseInt(line.substring(5).trim());
                return new ServerHandle(proc, port);
            }
        }
        proc.destroy();
        throw new IOException("Python transport server did not emit PORT=...");
    }

    @Test
    void fullStreamRoundTripsThroughPythonServer(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir)) { /* close */ }
        try (ServerHandle srv = startPythonServer(dir.resolve("src.tio"))) {
            TransportClient client = new TransportClient(srv.url());
            List<TransportReader.PacketRecord> packets = client.fetchPackets(null);
            // Expect: StreamHeader + DatasetHeader + 5 AU + EndOfDataset + EndOfStream
            assertEquals(PacketType.STREAM_HEADER, packets.get(0).header.packetType);
            assertEquals(PacketType.END_OF_STREAM,
                    packets.get(packets.size() - 1).header.packetType);
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(5, auCount);
        }
    }

    @Test
    void msLevelFilterReducesAUCount(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir)) { /* close */ }
        try (ServerHandle srv = startPythonServer(dir.resolve("src.tio"))) {
            TransportClient client = new TransportClient(srv.url());
            Map<String, Object> filters = new LinkedHashMap<>();
            filters.put("ms_level", 2);
            List<TransportReader.PacketRecord> packets = client.fetchPackets(filters);
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(2, auCount);
        }
    }

    @Test
    void streamToFileMaterializes(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir)) { /* close */ }
        Path out = dir.resolve("rt.tio");
        try (ServerHandle srv = startPythonServer(dir.resolve("src.tio"))) {
            TransportClient client = new TransportClient(srv.url());
            try (SpectralDataset rt = client.streamToFile(out.toString(), null)) {
                assertEquals("M68 server fixture", rt.title());
                AcquisitionRun run = rt.msRuns().get("run_0001");
                assertNotNull(run);
                assertEquals(5, run.spectrumCount());
                MassSpectrum s1 = (MassSpectrum) run.objectAtIndex(1);
                assertEquals(2, s1.msLevel());
            }
        }
    }
}
