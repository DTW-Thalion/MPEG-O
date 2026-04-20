/*
 * MPEG-O Java Implementation — v0.10 M69.
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.transport;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class AcquisitionSimulatorTest {

    @Test
    void streamCount() throws Exception {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        AcquisitionSimulator sim = new AcquisitionSimulator(
                10.0, 2.0, 0.3, 100.0, 2000.0, 200, 1L);
        int n;
        try (TransportWriter tw = new TransportWriter(buf)) {
            n = sim.streamToWriter(tw);
        }
        assertEquals(20, n);
        try (TransportReader tr = new TransportReader(buf.toByteArray())) {
            List<TransportReader.PacketRecord> packets = tr.readAllPackets();
            long auCount = packets.stream()
                    .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                    .count();
            assertEquals(20, auCount);
        }
    }

    @Test
    void deterministicWithSeed() throws Exception {
        ByteArrayOutputStream a = new ByteArrayOutputStream();
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(a)) {
            new AcquisitionSimulator(5.0, 1.0, 0.3, 100.0, 2000.0, 50, 42L)
                    .streamToWriter(tw);
        }
        try (TransportWriter tw = new TransportWriter(b)) {
            new AcquisitionSimulator(5.0, 1.0, 0.3, 100.0, 2000.0, 50, 42L)
                    .streamToWriter(tw);
        }
        // Timestamp_ns differs per packet; compare packet *payloads* only.
        byte[][] pa = payloadsOnly(a.toByteArray());
        byte[][] pb = payloadsOnly(b.toByteArray());
        assertEquals(pa.length, pb.length);
        for (int i = 0; i < pa.length; i++) {
            assertArrayEquals(pa[i], pb[i], "payload " + i);
        }
    }

    @Test
    void differentSeedsDiffer() throws Exception {
        ByteArrayOutputStream a = new ByteArrayOutputStream();
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(a)) {
            new AcquisitionSimulator(5.0, 1.0, 0.3, 100.0, 2000.0, 50, 1L)
                    .streamToWriter(tw);
        }
        try (TransportWriter tw = new TransportWriter(b)) {
            new AcquisitionSimulator(5.0, 1.0, 0.3, 100.0, 2000.0, 50, 2L)
                    .streamToWriter(tw);
        }
        assertFalse(java.util.Arrays.equals(a.toByteArray(), b.toByteArray()));
    }

    @Test
    void rtMonotonic() throws Exception {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(buf)) {
            new AcquisitionSimulator(20.0, 1.5, 0.3, 100.0, 2000.0, 50, 7L)
                    .streamToWriter(tw);
        }
        try (TransportReader tr = new TransportReader(buf.toByteArray())) {
            double lastRt = -1.0;
            for (TransportReader.PacketRecord rec : tr.readAllPackets()) {
                if (rec.header.packetType != PacketType.ACCESS_UNIT) continue;
                AccessUnit au = AccessUnit.decode(rec.payload);
                assertTrue(au.retentionTime >= lastRt, "RT went backwards");
                lastRt = au.retentionTime;
            }
        }
    }

    @Test
    void materializesAsValidMpgo(@TempDir Path dir) throws Exception {
        Path mots = dir.resolve("sim.mots");
        try (TransportWriter tw = new TransportWriter(mots)) {
            new AcquisitionSimulator(5.0, 1.0, 0.3, 100.0, 2000.0, 50, 42L)
                    .streamToWriter(tw);
        }
        try (TransportReader tr = new TransportReader(mots);
             com.dtwthalion.mpgo.SpectralDataset rt =
                     tr.materializeTo(dir.resolve("sim.mpgo").toString())) {
            assertEquals("Simulated acquisition", rt.title());
            com.dtwthalion.mpgo.AcquisitionRun run =
                    rt.msRuns().get("simulated_run");
            assertNotNull(run);
            assertEquals(5, run.spectrumCount());
        }
    }

    private static byte[][] payloadsOnly(byte[] stream) {
        // Parse sequential packets; capture payloads.
        java.util.List<byte[]> payloads = new java.util.ArrayList<>();
        int offset = 0;
        while (offset < stream.length) {
            if (stream.length - offset < PacketHeader.HEADER_SIZE) break;
            byte[] head = new byte[PacketHeader.HEADER_SIZE];
            System.arraycopy(stream, offset, head, 0, head.length);
            PacketHeader h = PacketHeader.decode(head);
            offset += PacketHeader.HEADER_SIZE;
            byte[] pl = new byte[(int) h.payloadLength];
            System.arraycopy(stream, offset, pl, 0, pl.length);
            payloads.add(pl);
            offset += pl.length;
            if ((h.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0) offset += 4;
        }
        return payloads.toArray(new byte[0][]);
    }
}
