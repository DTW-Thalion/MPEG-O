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
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * FD-1 Phase C-2a (Java) — server_kek_id in ProtectionMetadata. Mirrors the
 * Python {@code test_fd1_c2a_server_kek_id.py}: append-only field, byte-
 * identical when absent, round-trips through the packet codec and storage.
 */
class ServerKekIdProtectionTest {

    @TempDir Path tempDir;

    private static final byte[] SERVER = filled(48, (byte) 0x11);
    private static final byte[] RESEARCHER = filled(1568, (byte) 0x22);
    private static final String KID = "server:kek-proj-adni";

    private static byte[] filled(int n, byte v) {
        byte[] b = new byte[n];
        Arrays.fill(b, v);
        return b;
    }

    // ── packet codec ──────────────────────────────────────────────────

    @Test
    void absentServerKekIdIsByteIdentical() {
        byte[] withNull = EncryptedTransport.encodeProtection(
            "aes-256-gcm", "aes-256-gcm", SERVER, List.of(), null);
        byte[] legacy = EncryptedTransport.encodeProtection(
            "aes-256-gcm", "aes-256-gcm", SERVER, List.of());
        assertArrayEquals(legacy, withNull);
        EncryptedTransport.ProtectionMeta pm =
            EncryptedTransport.parseProtection(withNull);
        assertNull(pm.serverKekId());
    }

    @Test
    void serverKekIdRoundTripsSingleRecipient() {
        byte[] payload = EncryptedTransport.encodeProtection(
            "aes-256-gcm", "aes-256-gcm", SERVER, List.of(), KID);
        EncryptedTransport.ProtectionMeta pm =
            EncryptedTransport.parseProtection(payload);
        assertEquals(KID, pm.serverKekId());
        assertArrayEquals(SERVER, pm.wrappedDek());
        assertTrue(pm.additionalRecipients().isEmpty());
    }

    @Test
    void serverKekIdRoundTripsWithAdditional() {
        List<EncryptedTransport.Recipient> add = List.of(
            new EncryptedTransport.Recipient("researcher", "ml-kem-1024", RESEARCHER));
        byte[] payload = EncryptedTransport.encodeProtection(
            "aes-256-gcm", "aes-256-gcm", SERVER, add, KID);
        EncryptedTransport.ProtectionMeta pm =
            EncryptedTransport.parseProtection(payload);
        assertEquals(KID, pm.serverKekId());
        assertEquals(1, pm.additionalRecipients().size());
        assertEquals("researcher", pm.additionalRecipients().get(0).recipientId());
    }

    // ── storage carriage ──────────────────────────────────────────────

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
                "c2a", "ISA-C2A", List.of(run), List.of(), List.of(), List.of())) { }
        PerAUFile.encryptFile(path, filled(32, (byte) 0x5A), false, "hdf5");
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
    void serverKekIdStorageRoundTrip() throws Exception {
        String src = buildEncryptedFixture("kid_src.h5");
        EncryptedTransport.stampTransportWrappedDek(
            src, SERVER, "aes-256-gcm", List.of(), KID, "hdf5");
        String dst = roundTrip(src, "kid_dst.h5");
        assertEquals(KID, EncryptedTransport.readTransportServerKekId(dst, "hdf5"));
    }

    @Test
    void byokHasNoServerKekId() throws Exception {
        String src = buildEncryptedFixture("byok_src.h5");
        EncryptedTransport.stampTransportWrappedDek(
            src, SERVER, "aes-256-gcm", "hdf5");   // no server_kek_id
        String dst = roundTrip(src, "byok_dst.h5");
        assertNull(EncryptedTransport.readTransportServerKekId(dst, "hdf5"));
    }
}
