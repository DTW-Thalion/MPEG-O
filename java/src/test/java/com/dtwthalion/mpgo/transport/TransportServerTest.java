/*
 * MPEG-O Java Implementation — v0.10 M68.5.
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.transport;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.Enums;
import com.dtwthalion.mpgo.InstrumentConfig;
import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class TransportServerTest {

    private static SpectralDataset buildFixture(Path dir, String name) {
        int n = 5;
        int p = 3;
        double[] mz = new double[n * p];
        double[] intensity = new double[n * p];
        for (int i = 0; i < n * p; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = 100.0 * (i + 1);
        }
        long[] offsets = {0, 3, 6, 9, 12};
        int[] lengths = {3, 3, 3, 3, 3};
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
        AcquisitionRun run = new AcquisitionRun("run_0001",
                Enums.AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("", "", "", "", "", ""),
                channels, List.of(), List.of(), "", 0.0);
        Path mpgo = dir.resolve(name);
        return SpectralDataset.create(mpgo.toString(),
                "M68.5 server fixture", "ISA-M685",
                List.of(run), List.of(), List.of(), List.of());
    }

    @Test
    void javaClientAgainstJavaServerUnfiltered(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.mpgo")) { /* close */ }

        TransportServer server = new TransportServer(
                dir.resolve("src.mpgo").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            List<TransportReader.PacketRecord> packets = client.fetchPackets(null);
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(5, auCount);
            assertEquals(PacketType.STREAM_HEADER, packets.get(0).header.packetType);
            assertEquals(PacketType.END_OF_STREAM,
                    packets.get(packets.size() - 1).header.packetType);
        } finally {
            server.stop();
        }
    }

    @Test
    void javaServerFiltersByMsLevel(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.mpgo")) { /* close */ }

        TransportServer server = new TransportServer(
                dir.resolve("src.mpgo").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> filters = new LinkedHashMap<>();
            filters.put("ms_level", 2);
            List<TransportReader.PacketRecord> packets = client.fetchPackets(filters);
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(2, auCount);
        } finally {
            server.stop();
        }
    }

    @Test
    void javaServerRtRange(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.mpgo")) { /* close */ }

        TransportServer server = new TransportServer(
                dir.resolve("src.mpgo").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> filters = new LinkedHashMap<>();
            filters.put("rt_min", 2.5);
            filters.put("rt_max", 4.0);
            List<TransportReader.PacketRecord> packets = client.fetchPackets(filters);
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(2, auCount);
        } finally {
            server.stop();
        }
    }

    @Test
    void javaServerMaxAuCap(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.mpgo")) { /* close */ }

        TransportServer server = new TransportServer(
                dir.resolve("src.mpgo").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> filters = new LinkedHashMap<>();
            filters.put("max_au", 2);
            List<TransportReader.PacketRecord> packets = client.fetchPackets(filters);
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(2, auCount);
        } finally {
            server.stop();
        }
    }

    @Test
    void materializesAfterStreaming(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildFixture(dir, "src.mpgo")) { /* close */ }

        TransportServer server = new TransportServer(
                dir.resolve("src.mpgo").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Path out = dir.resolve("rt.mpgo");
            try (SpectralDataset rt = client.streamToFile(out.toString(), null)) {
                assertEquals("M68.5 server fixture", rt.title());
                assertNotNull(rt.msRuns().get("run_0001"));
                assertEquals(5, rt.msRuns().get("run_0001").spectrumCount());
            }
        } finally {
            server.stop();
        }
    }
}
