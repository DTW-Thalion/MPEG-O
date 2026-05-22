/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.transport.TransportWriter;

import java.io.ByteArrayOutputStream;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * FD-1 Phase A-2 (Java) — multi-recipient ProtectionMetadata carriage.
 * Mirrors the Python {@code test_fd1_multi_recipient_protection.py}: a
 * per-run DEK wrapped for several recipients survives stamp → packet →
 * read → store, and single-recipient stays byte-identical to before.
 */
class MultiRecipientProtectionTest {

    @TempDir
    Path tempDir;

    private static final byte[] SERVER = filled(48, (byte) 0x11);
    private static final byte[] RESEARCHER = filled(1639, (byte) 0x22);

    private static byte[] filled(int n, byte v) {
        byte[] b = new byte[n];
        java.util.Arrays.fill(b, v);
        return b;
    }

    private static byte[] testKey() {
        return filled(32, (byte) 0x5A);
    }

    private String buildEncryptedFixture(String fname) throws Exception {
        String path = tempDir.resolve(fname).toString();
        int n = 3;
        SpectrumIndex idx = new SpectrumIndex(n,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        double[] mz = new double[12], intensity = new double[12];
        for (int i = 0; i < 12; i++) { mz[i] = 100.0 + i; intensity[i] = (i + 1) * 10.0; }
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);
        try (SpectralDataset ds = SpectralDataset.create(path,
                "fd1", "ISA-FD1", List.of(run), List.of(), List.of(), List.of())) { }
        PerAUFile.encryptFile(path, testKey(), false, "hdf5");
        return path;
    }

    private String roundTrip(String src, String dstName) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (TransportWriter writer = new TransportWriter(bos)) {
            EncryptedTransport.writeEncryptedDataset(src, writer, "hdf5");
        }
        String dst = tempDir.resolve(dstName).toString();
        EncryptedTransport.readEncryptedToPath(dst, bos.toByteArray(), "hdf5");
        return dst;
    }

    @Test
    void multiRecipientCarriageRoundTrip() throws Exception {
        String src = buildEncryptedFixture("multi_src.h5");
        EncryptedTransport.stampTransportWrappedDek(
            src, SERVER, "aes-256-gcm",
            List.of(new EncryptedTransport.Recipient(
                "researcher", "ml-kem-1024", RESEARCHER)),
            "hdf5");

        String dst = roundTrip(src, "multi_dst.h5");

        // primary accessor unchanged
        EncryptedTransport.WrappedDek primary =
            EncryptedTransport.readTransportWrappedDek(dst, "hdf5");
        assertArrayEquals(SERVER, primary.wrappedDek());
        assertEquals("aes-256-gcm", primary.kekAlgorithm());

        // full recipient list recovered through the round-trip
        List<EncryptedTransport.Recipient> recips =
            EncryptedTransport.readTransportRecipients(dst, "hdf5");
        assertEquals(2, recips.size());
        assertEquals("", recips.get(0).recipientId());
        assertArrayEquals(SERVER, recips.get(0).wrappedDek());
        assertEquals("researcher", recips.get(1).recipientId());
        assertEquals("ml-kem-1024", recips.get(1).kekAlgorithm());
        assertArrayEquals(RESEARCHER, recips.get(1).wrappedDek());
    }

    @Test
    void singleRecipientUnchanged() throws Exception {
        String src = buildEncryptedFixture("single_src.h5");
        EncryptedTransport.stampTransportWrappedDek(
            src, SERVER, "aes-256-gcm", "hdf5");   // no additional recipients

        String dst = roundTrip(src, "single_dst.h5");

        List<EncryptedTransport.Recipient> recips =
            EncryptedTransport.readTransportRecipients(dst, "hdf5");
        assertEquals(1, recips.size());
        assertEquals("", recips.get(0).recipientId());
        assertArrayEquals(SERVER, recips.get(0).wrappedDek());
        assertEquals("aes-256-gcm", recips.get(0).kekAlgorithm());
    }
}
