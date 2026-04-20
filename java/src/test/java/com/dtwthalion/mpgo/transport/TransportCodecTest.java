/*
 * MPEG-O Java Implementation
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.transport;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.Enums;
import com.dtwthalion.mpgo.InstrumentConfig;
import com.dtwthalion.mpgo.MassSpectrum;
import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.Spectrum;
import com.dtwthalion.mpgo.SpectrumIndex;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** v0.10 M67: Java transport codec round-trip tests. */
class TransportCodecTest {

    // ── helpers ───────────────────────────────────────────────────

    private static byte[] f64le(double... values) {
        ByteBuffer buf = ByteBuffer.allocate(values.length * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (double v : values) buf.putDouble(v);
        return buf.array();
    }

    private static SpectralDataset makeFixture(Path dir) {
        int n = 3;
        int p = 4;
        double[] mzAll = new double[n * p];
        double[] intAll = new double[n * p];
        for (int i = 0; i < n * p; i++) {
            mzAll[i] = 100.0 + i;
            intAll[i] = 1000.0 * (i + 1);
        }
        long[] offsets = {0, 4, 8};
        int[] lengths = {4, 4, 4};
        double[] rts = {1.0, 2.0, 3.0};
        int[] msLevels = {1, 2, 1};
        int[] pols = {1, 1, 1};
        double[] pmzs = {0.0, 500.25, 0.0};
        int[] pcs = {0, 2, 0};
        double[] bpis = new double[n];
        for (int i = 0; i < n; i++) {
            double best = 0;
            for (int k = 0; k < p; k++) best = Math.max(best, intAll[i * p + k]);
            bpis[i] = best;
        }
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mzAll);
        channels.put("intensity", intAll);
        InstrumentConfig cfg = new InstrumentConfig("", "", "", "", "", "");
        AcquisitionRun run = new AcquisitionRun("run_0001",
                Enums.AcquisitionMode.MS1_DDA, idx, cfg, channels,
                List.of(), List.of(), "", 0.0);
        Path mpgo = dir.resolve("src.mpgo");
        return SpectralDataset.create(mpgo.toString(),
                "M67 round-trip fixture", "ISA-M67-TEST",
                List.of(run), List.of(), List.of(), List.of());
    }

    // ── PacketHeader ──────────────────────────────────────────────

    @Test
    void packetHeaderRoundTrip() {
        PacketHeader h = new PacketHeader(PacketType.ACCESS_UNIT,
                PacketHeader.FLAG_HAS_CHECKSUM, 42, 12345L, 9999L,
                1_700_000_000_000_000_000L);
        byte[] encoded = h.encode();
        assertEquals(PacketHeader.HEADER_SIZE, encoded.length);
        PacketHeader d = PacketHeader.decode(encoded);
        assertEquals(PacketType.ACCESS_UNIT, d.packetType);
        assertEquals(42, d.datasetId);
        assertEquals(12345L, d.auSequence);
        assertEquals(9999L, d.payloadLength);
        assertEquals(1_700_000_000_000_000_000L, d.timestampNs);
    }

    @Test
    void packetHeaderBadMagicRejected() {
        byte[] bad = new byte[PacketHeader.HEADER_SIZE];
        bad[0] = 'X'; bad[1] = 'X'; bad[2] = 1;
        assertThrows(IllegalArgumentException.class, () -> PacketHeader.decode(bad));
    }

    @Test
    void crc32cKnownVector() {
        // "123456789" → 0xE3069283 (Castagnoli reference)
        byte[] v = "123456789".getBytes();
        assertEquals(0xE3069283, Crc32c.compute(v));
        assertEquals(0, Crc32c.compute(new byte[0]));
    }

    // ── AccessUnit ────────────────────────────────────────────────

    @Test
    void accessUnitRoundTrip() {
        ChannelData mz = new ChannelData("mz",
                Enums.Precision.FLOAT64.ordinal(),
                Enums.Compression.NONE.ordinal(),
                3, f64le(100.0, 200.0, 300.0));
        ChannelData intensity = new ChannelData("intensity",
                Enums.Precision.FLOAT64.ordinal(),
                Enums.Compression.NONE.ordinal(),
                3, f64le(1000.0, 2000.0, 3000.0));
        AccessUnit au = new AccessUnit(0, 0, 2, 0,
                123.456, 500.25, 2, 0.0, 1.0e6,
                List.of(mz, intensity), 0, 0, 0);
        AccessUnit d = AccessUnit.decode(au.encode());
        assertEquals(0, d.spectrumClass);
        assertEquals(2, d.msLevel);
        assertEquals(123.456, d.retentionTime);
        assertEquals(500.25, d.precursorMz);
        assertEquals(2, d.precursorCharge);
        assertEquals(1.0e6, d.basePeakIntensity);
        assertEquals(2, d.channels.size());
        assertEquals("mz", d.channels.get(0).name);
        assertEquals("intensity", d.channels.get(1).name);
    }

    @Test
    void msImagePixelAURoundTrip() {
        ChannelData ch = new ChannelData("intensity",
                Enums.Precision.FLOAT64.ordinal(),
                Enums.Compression.NONE.ordinal(),
                1, f64le(500.0));
        AccessUnit au = new AccessUnit(4, 6, 1, 0,
                0.0, 0.0, 0, 0.0, 500.0,
                List.of(ch), 10L, 20L, 0L);
        AccessUnit d = AccessUnit.decode(au.encode());
        assertEquals(4, d.spectrumClass);
        assertEquals(10L, d.pixelX);
        assertEquals(20L, d.pixelY);
        assertEquals(0L, d.pixelZ);
    }

    // ── End-to-end round-trip ─────────────────────────────────────

    @Test
    void fileToTransportToFileRoundTrip(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = makeFixture(dir)) { /* close */ }

        // Reopen the fixture file from disk.
        SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());

        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(stream)) {
            tw.writeDataset(src);
        }
        src.close();

        assertTrue(stream.size() > 0);

        Path rtPath = dir.resolve("rt.mpgo");
        try (TransportReader tr = new TransportReader(stream.toByteArray())) {
            try (SpectralDataset rt = tr.materializeTo(rtPath.toString())) {
                assertEquals("M67 round-trip fixture", rt.title());
                assertEquals("ISA-M67-TEST", rt.isaInvestigationId());
                assertEquals(1, rt.msRuns().size());
                AcquisitionRun rtRun = rt.msRuns().get("run_0001");
                assertNotNull(rtRun);
                assertEquals(3, rtRun.spectrumCount());
                Spectrum s1 = rtRun.objectAtIndex(1);
                assertTrue(s1 instanceof MassSpectrum);
                assertEquals(2, ((MassSpectrum) s1).msLevel());
                assertEquals(2.0, s1.scanTimeSeconds(), 1e-9);
                assertEquals(500.25, s1.precursorMz(), 1e-9);
            }
        }
    }

    @Test
    void packetCountIsSeven(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = makeFixture(dir)) { /* close */ }
        SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());
        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(stream)) {
            tw.writeDataset(src);
        }
        src.close();
        try (TransportReader tr = new TransportReader(stream.toByteArray())) {
            List<TransportReader.PacketRecord> packets = tr.readAllPackets();
            // StreamHeader + DatasetHeader + 3 AU + EndOfDataset + EndOfStream = 7
            assertEquals(7, packets.size());
            assertEquals(PacketType.STREAM_HEADER, packets.get(0).header.packetType);
            assertEquals(PacketType.END_OF_STREAM,
                    packets.get(packets.size() - 1).header.packetType);
        }
    }

    @Test
    void zlibCompressionRoundTrip(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = makeFixture(dir)) { /* close */ }
        SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());

        ByteArrayOutputStream plain = new ByteArrayOutputStream();
        ByteArrayOutputStream compressed = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(plain)) {
            tw.writeDataset(src);
        }
        try (TransportWriter tw = new TransportWriter(compressed)) {
            tw.setUseCompression(true);
            tw.writeDataset(src);
        }
        src.close();

        // Small fixture; compressed should at least not explode past
        // plain + zlib overhead.
        assertTrue(compressed.size() <= plain.size() + 128);

        Path out = dir.resolve("rt_zlib.mpgo");
        try (TransportReader tr = new TransportReader(compressed.toByteArray());
             SpectralDataset rt = tr.materializeTo(out.toString())) {
            AcquisitionRun run = rt.msRuns().get("run_0001");
            assertNotNull(run);
            assertEquals(3, run.spectrumCount());
            // MS2 spectrum at index 1 should still have precursor_mz=500.25.
            MassSpectrum s1 = (MassSpectrum) run.objectAtIndex(1);
            assertEquals(500.25, s1.precursorMz(), 1e-9);
        }
    }

    @Test
    void checksumCorruptionIsDetected(@TempDir Path dir) throws Exception {
        try (SpectralDataset src = makeFixture(dir)) { /* close */ }
        SpectralDataset src = SpectralDataset.open(dir.resolve("src.mpgo").toString());
        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        try (TransportWriter tw = new TransportWriter(stream)) {
            tw.setUseChecksum(true);
            tw.writeDataset(src);
        }
        src.close();
        byte[] raw = stream.toByteArray();
        raw[raw.length / 2] ^= (byte) 0xFF;
        try (TransportReader tr = new TransportReader(raw)) {
            assertThrows(Exception.class, tr::readAllPackets);
        }
    }
}
