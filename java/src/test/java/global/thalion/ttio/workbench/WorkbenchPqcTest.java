/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.protection.PostQuantumCrypto;
import global.thalion.ttio.workbench.encryption.ProtectionMetadata;
import global.thalion.ttio.workbench.pqc.WorkbenchPqc;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.*;

/**
 * W6.3 -- workbench PQC client (ML-KEM-1024 + ML-DSA-87). Mirrors the
 * Python {@code test_pqc.py}. Java PQC (BouncyCastle) is always
 * present, so the crypto round-trips are not gated.
 */
class WorkbenchPqcTest {

    // Cross-language anchor: the PQC-envelope ProtectionMetadata shape.
    private static final String PQC_ANCHOR_JSON =
        "{\"cipher_suite\":\"aes-256-gcm\",\"kek_algorithm\":\"ml-kem-1024\","
        + "\"public_key\":\"\",\"signature_algorithm\":\"ml-dsa-87\",\"wrapped_dek\":\"\"}";

    @Test
    void sealRefusesWithoutPreview() {
        assertThrows(WorkbenchPqc.PqcPreviewDisabledException.class, () ->
            WorkbenchPqc.sealPqc("x".getBytes(StandardCharsets.UTF_8),
                new byte[1568], false));
    }

    @Test
    void openRefusesWithoutPreview() {
        ProtectionMetadata meta = new ProtectionMetadata(
            "aes-256-gcm", "ml-kem-1024", new byte[]{1}, "none", new byte[0]);
        assertThrows(WorkbenchPqc.PqcPreviewDisabledException.class, () ->
            WorkbenchPqc.openPqc(new byte[1], meta, new byte[3168], false));
    }

    @Test
    void pqcEnvelopeJsonAnchor() {
        ProtectionMetadata meta = new ProtectionMetadata(
            "aes-256-gcm", "ml-kem-1024", new byte[0], "ml-dsa-87", new byte[0]);
        assertEquals(PQC_ANCHOR_JSON, meta.toJson());
    }

    @Test
    void pqcEnvelopeRoundTrip() {
        PostQuantumCrypto.KeyPair kp = WorkbenchPqc.kemKeygen();
        byte[] payload = "post-quantum sealed payload".repeat(32)
            .getBytes(StandardCharsets.UTF_8);
        WorkbenchPqc.PqcSealed sealed =
            WorkbenchPqc.sealPqc(payload, kp.publicKey(), true);
        assertEquals("ml-kem-1024", sealed.protection().kekAlgorithm);
        assertTrue(sealed.protection().wrappedDek.length > 0);
        assertEquals(0, sealed.signature().length);
        byte[] restored = WorkbenchPqc.openPqc(
            sealed.ciphertext(), sealed.protection(), kp.privateKey(), true);
        assertArrayEquals(payload, restored);
    }

    @Test
    void pqcSignedRoundTrip() {
        PostQuantumCrypto.KeyPair kem = WorkbenchPqc.kemKeygen();
        PostQuantumCrypto.KeyPair sig = WorkbenchPqc.sigKeygen();
        byte[] payload = "signed + sealed".getBytes(StandardCharsets.UTF_8);
        WorkbenchPqc.PqcSealed sealed = WorkbenchPqc.sealPqc(
            payload, kem.publicKey(), true, sig.privateKey(), sig.publicKey());
        assertEquals("ml-dsa-87", sealed.protection().signatureAlgorithm);
        assertArrayEquals(sig.publicKey(), sealed.protection().publicKey);
        assertTrue(sealed.signature().length > 0);
        assertTrue(WorkbenchPqc.verifyPqc(
            sealed.ciphertext(), sealed.signature(), sig.publicKey()));
        byte[] bad = sealed.ciphertext().clone();
        bad[bad.length - 1] ^= 0xFF;
        assertFalse(WorkbenchPqc.verifyPqc(bad, sealed.signature(), sig.publicKey()));
        byte[] restored = WorkbenchPqc.openPqc(
            sealed.ciphertext(), sealed.protection(), kem.privateKey(), true);
        assertArrayEquals(payload, restored);
    }

    @Test
    void pqcWrongRecipientKeyFails() {
        PostQuantumCrypto.KeyPair a = WorkbenchPqc.kemKeygen();
        PostQuantumCrypto.KeyPair b = WorkbenchPqc.kemKeygen();
        WorkbenchPqc.PqcSealed sealed = WorkbenchPqc.sealPqc(
            "secret".getBytes(StandardCharsets.UTF_8), a.publicKey(), true);
        assertThrows(RuntimeException.class, () ->
            WorkbenchPqc.openPqc(sealed.ciphertext(), sealed.protection(),
                b.privateKey(), true));
    }
}
