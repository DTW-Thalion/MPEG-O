/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.protection;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.Enums;
import com.dtwthalion.mpgo.InstrumentConfig;
import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.SpectrumIndex;
import com.dtwthalion.mpgo.transport.PacketHeader;
import com.dtwthalion.mpgo.transport.PacketType;
import com.dtwthalion.mpgo.transport.TransportReader;
import com.dtwthalion.mpgo.transport.TransportWriter;

import java.io.ByteArrayOutputStream;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v1.0 encrypted transport round-trip: encrypt fixture → write
 * stream → read stream → decrypt destination. Plaintext channel
 * bytes survive transport bit-for-bit in both channel-only and
 * encrypted-header modes.
 */
class EncryptedTransportTest {

    @TempDir
    Path tempDir;

    private static byte[] testKey() {
        byte[] k = new byte[32];
        java.util.Arrays.fill(k, (byte) 0x77);
        return k;
    }

    private String buildFixture(String fname, boolean encryptHeaders)
            throws Exception {
        String path = tempDir.resolve(fname).toString();
        int nSpectra = 3, perSpectrum = 4;
        int total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        long[] offsets = { 0, 4, 8 };
        int[] lengths = { 4, 4, 4 };
        double[] rts = { 1.0, 2.0, 3.0 };
        int[] msLevels = { 1, 2, 1 };
        int[] pols = { 1, 1, 1 };
        double[] pmzs = { 0.0, 500.0, 0.0 };
        int[] pcs = { 0, 2, 0 };
        double[] bpis = { 40.0, 80.0, 120.0 };

        SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths,
            rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);

        try (SpectralDataset ds = SpectralDataset.create(path,
                "enc-transport fixture", "ISA-ENC-TX",
                List.of(run), List.of(), List.of(), List.of())) { }

        PerAUFile.encryptFile(path, testKey(), encryptHeaders, "hdf5");
        return path;
    }

    @Test
    void roundTripChannelOnly() throws Exception {
        String src = buildFixture("rt_src_ch.h5", false);
        String dst = tempDir.resolve("rt_dst_ch.h5").toString();

        assertTrue(EncryptedTransport.isPerAUEncrypted(src, "hdf5"));

        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (TransportWriter writer = new TransportWriter(bos)) {
            EncryptedTransport.writeEncryptedDataset(src, writer, "hdf5");
        }
        byte[] stream = bos.toByteArray();
        assertTrue(stream.length > 0);

        // Sanity-check that AU packets carry FLAG_ENCRYPTED.
        TransportReader reader = new TransportReader(stream);
        List<TransportReader.PacketRecord> packets = reader.readAllPackets();
        reader.close();
        int auCount = 0, allEncrypted = 0, headerEncFlagged = 0;
        for (TransportReader.PacketRecord r : packets) {
            if (r.header.packetType == PacketType.ACCESS_UNIT) {
                auCount++;
                if ((r.header.flags & PacketHeader.FLAG_ENCRYPTED) != 0) allEncrypted++;
                if ((r.header.flags & PacketHeader.FLAG_ENCRYPTED_HEADER) != 0) headerEncFlagged++;
            }
        }
        assertEquals(3, auCount);
        assertEquals(3, allEncrypted);
        assertEquals(0, headerEncFlagged);

        EncryptedTransport.readEncryptedToPath(dst, stream, "hdf5");
        assertTrue(EncryptedTransport.isPerAUEncrypted(dst, "hdf5"));

        Map<String, PerAUFile.DecryptedRun> srcPlain =
            PerAUFile.decryptFile(src, testKey(), "hdf5");
        Map<String, PerAUFile.DecryptedRun> dstPlain =
            PerAUFile.decryptFile(dst, testKey(), "hdf5");
        assertArrayEquals(srcPlain.get("run_0001").channels().get("mz"),
                           dstPlain.get("run_0001").channels().get("mz"));
        assertArrayEquals(srcPlain.get("run_0001").channels().get("intensity"),
                           dstPlain.get("run_0001").channels().get("intensity"));
    }

    @Test
    void roundTripEncryptedHeaders() throws Exception {
        String src = buildFixture("rt_src_hdr.h5", true);
        String dst = tempDir.resolve("rt_dst_hdr.h5").toString();

        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (TransportWriter writer = new TransportWriter(bos)) {
            EncryptedTransport.writeEncryptedDataset(src, writer, "hdf5");
        }
        byte[] stream = bos.toByteArray();

        TransportReader reader = new TransportReader(stream);
        List<TransportReader.PacketRecord> packets = reader.readAllPackets();
        reader.close();
        int auEncryptedHeader = 0;
        for (TransportReader.PacketRecord r : packets) {
            if (r.header.packetType == PacketType.ACCESS_UNIT
                    && (r.header.flags & PacketHeader.FLAG_ENCRYPTED_HEADER) != 0) {
                auEncryptedHeader++;
            }
        }
        assertEquals(3, auEncryptedHeader);

        EncryptedTransport.readEncryptedToPath(dst, stream, "hdf5");
        Map<String, PerAUFile.DecryptedRun> srcPlain =
            PerAUFile.decryptFile(src, testKey(), "hdf5");
        Map<String, PerAUFile.DecryptedRun> dstPlain =
            PerAUFile.decryptFile(dst, testKey(), "hdf5");
        assertArrayEquals(srcPlain.get("run_0001").channels().get("mz"),
                           dstPlain.get("run_0001").channels().get("mz"));
        // Header segments recovered with matching ms_levels.
        assertNotNull(dstPlain.get("run_0001").auHeaders());
        assertEquals(srcPlain.get("run_0001").auHeaders().size(),
                      dstPlain.get("run_0001").auHeaders().size());
        for (int i = 0; i < 3; i++) {
            assertEquals(
                srcPlain.get("run_0001").auHeaders().get(i).msLevel(),
                dstPlain.get("run_0001").auHeaders().get(i).msLevel());
            assertEquals(
                srcPlain.get("run_0001").auHeaders().get(i).retentionTime(),
                dstPlain.get("run_0001").auHeaders().get(i).retentionTime(),
                0.0);
        }
    }
}
