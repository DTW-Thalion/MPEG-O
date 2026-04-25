/*
 * TTI-O Java Implementation — v0.10 M71.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.10 M71: selective-access proportionality + ProtectionMetadata
 * wire round-trip.
 */
class SelectiveAccessTest {

    private static SpectralDataset buildLarge(Path path) {
        int n = 600;
        int points = 4;
        int total = n * points;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = 1.0 + i;
        }
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * points;
            lengths[i] = points;
        }
        double[] rts = new double[n];
        int[] msLevels = new int[n];
        int[] pols = new int[n];
        double[] pmzs = new double[n];
        int[] pcs = new int[n];
        double[] bpis = new double[n];
        for (int i = 0; i < n; i++) {
            rts[i] = 60.0 * i / (n - 1);
            msLevels[i] = (i % 2 == 0) ? 1 : 2;
            pols[i] = 1;
            pmzs[i] = msLevels[i] == 1 ? 0.0 : 500.0 + 0.1 * i;
            pcs[i] = msLevels[i] == 1 ? 0 : 2;
            double best = 0;
            for (int k = 0; k < points; k++) best = Math.max(best, intensity[i * points + k]);
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
        return SpectralDataset.create(path.toString(),
                "M71 selective-access fixture", "ISA-M71",
                List.of(run), List.of(), List.of(), List.of());
    }

    private static long countAUs(List<TransportReader.PacketRecord> packets) {
        return packets.stream()
                .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
                .count();
    }

    // ── selective access ─────────────────────────────────────────

    @Test
    void rtRangeFilterReducesTransfer(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildLarge(dir.resolve("src.tio"))) { /* close */ }
        TransportServer server = new TransportServer(
                dir.resolve("src.tio").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> rtRange = new LinkedHashMap<>();
            rtRange.put("rt_min", 10.0);
            rtRange.put("rt_max", 12.0);
            long filtered = countAUs(client.fetchPackets(rtRange));
            long full = countAUs(client.fetchPackets(null));
            double ratio = (double) filtered / full;
            assertTrue(ratio < 0.05, "RT filter should deliver <5%, got " + ratio);
            assertTrue(filtered > 0, "RT filter should match some AUs");
        } finally {
            server.stop();
        }
    }

    @Test
    void ms2FilterHalvesStream(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildLarge(dir.resolve("src.tio"))) { /* close */ }
        TransportServer server = new TransportServer(
                dir.resolve("src.tio").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> f = new LinkedHashMap<>();
            f.put("ms_level", 2);
            assertEquals(300, countAUs(client.fetchPackets(f)));
        } finally {
            server.stop();
        }
    }

    @Test
    void maxAuCapEnforced(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildLarge(dir.resolve("src.tio"))) { /* close */ }
        TransportServer server = new TransportServer(
                dir.resolve("src.tio").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> f = new LinkedHashMap<>();
            f.put("max_au", 100);
            List<TransportReader.PacketRecord> packets = client.fetchPackets(f);
            assertEquals(100, countAUs(packets));
            assertEquals(PacketType.END_OF_STREAM,
                    packets.get(packets.size() - 1).header.packetType);
        } finally {
            server.stop();
        }
    }

    @Test
    void combinedFiltersIntersect(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildLarge(dir.resolve("src.tio"))) { /* close */ }
        TransportServer server = new TransportServer(
                dir.resolve("src.tio").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> rtOnly = new LinkedHashMap<>();
            rtOnly.put("rt_min", 10.0); rtOnly.put("rt_max", 30.0);
            long rtOnlyCount = countAUs(client.fetchPackets(rtOnly));
            Map<String, Object> combined = new LinkedHashMap<>(rtOnly);
            combined.put("ms_level", 2);
            long combinedCount = countAUs(client.fetchPackets(combined));
            assertTrue(combinedCount < rtOnlyCount);
            double ratio = (double) combinedCount / rtOnlyCount;
            assertTrue(ratio >= 0.4 && ratio <= 0.6,
                    "combined/rt_only = " + ratio + ", expected ~0.5");
        } finally {
            server.stop();
        }
    }

    @Test
    void noMatchesYieldsSkeletonOnly(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = buildLarge(dir.resolve("src.tio"))) { /* close */ }
        TransportServer server = new TransportServer(
                dir.resolve("src.tio").toString(), "127.0.0.1", 0);
        server.start();
        try {
            TransportClient client = new TransportClient("ws://127.0.0.1:" + server.port());
            Map<String, Object> f = new LinkedHashMap<>();
            f.put("ms_level", 99);
            List<TransportReader.PacketRecord> packets = client.fetchPackets(f);
            assertEquals(0, countAUs(packets));
            assertEquals(PacketType.STREAM_HEADER, packets.get(0).header.packetType);
            assertEquals(PacketType.END_OF_STREAM,
                    packets.get(packets.size() - 1).header.packetType);
        } finally {
            server.stop();
        }
    }

    // ── ProtectionMetadata wire ─────────────────────────────────

    @Test
    void protectionMetadataRoundTripAesGcm() {
        byte[] wrapped = new byte[256];
        byte[] pk = new byte[32];
        for (int i = 0; i < wrapped.length; i++) wrapped[i] = 1;
        for (int i = 0; i < pk.length; i++) pk[i] = 2;
        ProtectionMetadata pm = new ProtectionMetadata(
                "aes-256-gcm", "rsa-oaep-sha256", wrapped, "ed25519", pk);
        ProtectionMetadata d = ProtectionMetadata.decode(pm.encode());
        assertEquals("aes-256-gcm", d.cipherSuite);
        assertEquals("rsa-oaep-sha256", d.kekAlgorithm);
        assertArrayEquals(wrapped, d.wrappedDek);
        assertEquals("ed25519", d.signatureAlgorithm);
        assertArrayEquals(pk, d.publicKey);
    }

    @Test
    void protectionMetadataRoundTripPqc() {
        byte[] wrapped = new byte[1568];
        byte[] pk = new byte[2592];
        java.util.Arrays.fill(wrapped, (byte) 0xFF);
        java.util.Arrays.fill(pk, (byte) 0xAA);
        ProtectionMetadata pm = new ProtectionMetadata(
                "aes-256-gcm", "ml-kem-1024", wrapped, "ml-dsa-87", pk);
        ProtectionMetadata d = ProtectionMetadata.decode(pm.encode());
        assertEquals("ml-kem-1024", d.kekAlgorithm);
        assertEquals("ml-dsa-87", d.signatureAlgorithm);
        assertArrayEquals(wrapped, d.wrappedDek);
        assertArrayEquals(pk, d.publicKey);
    }

    // ── encrypted flag on AU header ─────────────────────────────

    @Test
    void encryptedFlagRoundtrips() {
        PacketHeader h = new PacketHeader(PacketType.ACCESS_UNIT,
                PacketHeader.FLAG_ENCRYPTED, 1, 0, 38, 0);
        PacketHeader d = PacketHeader.decode(h.encode());
        assertTrue((d.flags & PacketHeader.FLAG_ENCRYPTED) != 0);
    }

    @Test
    void combinedFlags() {
        int flags = PacketHeader.FLAG_ENCRYPTED | PacketHeader.FLAG_HAS_CHECKSUM;
        PacketHeader h = new PacketHeader(PacketType.ACCESS_UNIT,
                flags, 1, 0, 38, 0);
        PacketHeader d = PacketHeader.decode(h.encode());
        assertTrue((d.flags & PacketHeader.FLAG_ENCRYPTED) != 0);
        assertTrue((d.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0);
    }
}
