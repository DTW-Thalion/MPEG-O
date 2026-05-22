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
import global.thalion.ttio.protection.EncryptedTransport;
import global.thalion.ttio.protection.EncryptionManager;
import global.thalion.ttio.protection.PerAUFile;
import global.thalion.ttio.transport.TransportWriter;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * FD-1 Phase B-2 (Java) — multi-recipient envelope client mechanics.
 *
 * <p>Daemon-free: exercises the exact wrap → stamp → write → read →
 * unwrap-by-recipient → decrypt composition that
 * {@link WorkbenchClient#uploadEncryptedMulti} /
 * {@link WorkbenchClient#downloadDecryptedMulti} perform, proving two
 * recipients each independently recover the <em>same</em> DEK and
 * plaintext. The full client methods (with the live daemon transport) are
 * covered by {@code WorkbenchLiveTest.multiRecipientUploadRoundTrip}.
 * Mirrors the Python {@code test_multi_recipient_client.py}. Uses two
 * symmetric KEKs so it needs no liboqs; the server-KEK + researcher-ML-KEM
 * shape is the live smoke's job.</p>
 */
class MultiRecipientClientTest {

    private static byte[] fill(int n, int v) {
        byte[] b = new byte[n];
        Arrays.fill(b, (byte) v);
        return b;
    }

    private static byte[] leBytes(double[] a) {
        ByteBuffer b = ByteBuffer.allocate(a.length * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (double d : a) b.putDouble(d);
        return b.array();
    }

    private static final double[] MZ = {100, 101, 102, 103, 104, 105,
                                         106, 107, 108, 109, 110, 111};
    private static final double[] INTENSITY = {10, 20, 30, 40, 50, 60,
                                               70, 80, 90, 100, 110, 120};

    private String buildEncrypted(Path tmp, byte[] dek) throws Exception {
        int n = 3;
        SpectrumIndex idx = new SpectrumIndex(n,
            new long[]{0, 4, 8}, new int[]{4, 4, 4},
            new double[]{1.0, 2.0, 3.0}, new int[]{1, 2, 1}, new int[]{1, 1, 1},
            new double[]{0.0, 500.0, 0.0}, new int[]{0, 2, 0},
            new double[]{40.0, 80.0, 120.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", MZ.clone());
        channels.put("intensity", INTENSITY.clone());
        AcquisitionRun run = new AcquisitionRun("run_0001",
            Enums.AcquisitionMode.MS1_DDA, idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), null, 0.0);
        String src = tmp.resolve("multi_src.tio").toString();
        try (SpectralDataset ds = SpectralDataset.create(src,
                "b2", "ISA-B2", List.of(run), List.of(), List.of(), List.of())) { }
        PerAUFile.encryptFile(src, dek, false, "hdf5");
        return src;
    }

    @Test
    void twoSymmetricRecipientsRoundTrip(@TempDir Path tmp) throws Exception {
        byte[] dek = fill(32, 0x5A);
        String src = buildEncrypted(tmp, dek);

        // The client wraps the one DEK once per recipient...
        byte[] serverKek = fill(32, 0x11);
        byte[] auditorKek = fill(32, 0x77);
        byte[] primaryWrapped =
            EncryptionManager.wrapKey(dek, serverKek, false, "aes-256-gcm");
        byte[] auditorWrapped =
            EncryptionManager.wrapKey(dek, auditorKek, false, "aes-256-gcm");
        EncryptedTransport.stampTransportWrappedDek(
            src, primaryWrapped, "aes-256-gcm",
            List.of(new EncryptedTransport.Recipient(
                "auditor", "aes-256-gcm", auditorWrapped)), "hdf5");

        // ...write the stream and read it back (round-trips the packet).
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (TransportWriter w = new TransportWriter(bos)) {
            EncryptedTransport.writeEncryptedDataset(src, w, "hdf5");
        }
        String out = tmp.resolve("multi_rt.tio").toString();
        EncryptedTransport.readEncryptedToPath(out, bos.toByteArray(), "hdf5");

        List<EncryptedTransport.Recipient> recips =
            EncryptedTransport.readTransportRecipients(out, "hdf5");
        assertEquals(2, recips.size());
        assertEquals("", recips.get(0).recipientId());        // primary
        assertEquals("auditor", recips.get(1).recipientId());

        // Each recipient selects its entry and unwraps the SAME DEK.
        byte[] dekServer = EncryptionManager.unwrapKey(
            recips.get(0).wrappedDek(), serverKek, "aes-256-gcm");
        byte[] dekAuditor = EncryptionManager.unwrapKey(
            recips.get(1).wrappedDek(), auditorKek, "aes-256-gcm");
        assertArrayEquals(dek, dekServer);
        assertArrayEquals(dek, dekAuditor);

        // ...and decrypts the identical plaintext.
        Map<String, PerAUFile.DecryptedRun> viaServer =
            PerAUFile.decryptFile(out, dekServer, "hdf5");
        Map<String, PerAUFile.DecryptedRun> viaAuditor =
            PerAUFile.decryptFile(out, dekAuditor, "hdf5");
        assertArrayEquals(leBytes(MZ),
            viaServer.get("run_0001").channels().get("mz"));
        assertArrayEquals(viaServer.get("run_0001").channels().get("mz"),
            viaAuditor.get("run_0001").channels().get("mz"));
        assertArrayEquals(viaServer.get("run_0001").channels().get("intensity"),
            viaAuditor.get("run_0001").channels().get("intensity"));
    }
}
