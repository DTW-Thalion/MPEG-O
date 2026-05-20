/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.encryption.ProtectionMetadata;
import global.thalion.ttio.workbench.encryption.ProtectionMode;
import global.thalion.ttio.workbench.encryption.WorkbenchEncryptor;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.*;

/**
 * W6.2 -- workbench client payload protection (BYOK / envelope).
 * Unit-level byte-equivalence round-trips + the cross-language
 * ProtectionMetadata JSON anchor (mirrors the Python
 * {@code test_encryption.py}).
 */
class WorkbenchEncryptionTest {

    // Repo convention: fixed test key is 0x77 * 32.
    private static byte[] fixedDek() {
        byte[] k = new byte[32];
        Arrays.fill(k, (byte) 0x77);
        return k;
    }

    private static byte[] fixedKek() {
        byte[] k = new byte[32];
        Arrays.fill(k, (byte) 0x42);
        return k;
    }

    // Cross-language anchors -- byte-identical to the Python mirror.
    private static final String BYOK_ANCHOR_JSON =
        "{\"cipher_suite\":\"aes-256-gcm\",\"kek_algorithm\":\"none\","
        + "\"public_key\":\"\",\"signature_algorithm\":\"none\",\"wrapped_dek\":\"\"}";
    private static final String SIGNED_ANCHOR_JSON =
        "{\"cipher_suite\":\"aes-256-gcm\",\"kek_algorithm\":\"none\","
        + "\"public_key\":\"AAEC\",\"signature_algorithm\":\"ml-dsa-87\",\"wrapped_dek\":\"\"}";

    @Test
    void byokRoundTrip() {
        byte[] payload = "the quick brown fox".repeat(64)
            .getBytes(StandardCharsets.UTF_8);
        WorkbenchEncryptor.SealedPayload sealed =
            WorkbenchEncryptor.seal(payload, ProtectionMode.BYOK, fixedDek(), null, null);
        assertFalse(Arrays.equals(payload, sealed.ciphertext()));
        assertEquals(0, sealed.protection().wrappedDek.length);
        byte[] restored = WorkbenchEncryptor.openSealed(
            sealed.ciphertext(), sealed.protection(), fixedDek(), null);
        assertArrayEquals(payload, restored);
    }

    @Test
    void envelopeRoundTrip() {
        byte[] payload = new byte[4096];
        new java.security.SecureRandom().nextBytes(payload);
        WorkbenchEncryptor.SealedPayload sealed =
            WorkbenchEncryptor.seal(payload, ProtectionMode.ENVELOPE, null, fixedKek(), null);
        assertTrue(sealed.protection().wrappedDek.length > 0);
        assertEquals("aes-256-gcm", sealed.protection().kekAlgorithm);
        byte[] restored = WorkbenchEncryptor.openSealed(
            sealed.ciphertext(), sealed.protection(), null, fixedKek());
        assertArrayEquals(payload, restored);
    }

    @Test
    void byokWrongKeyFails() {
        WorkbenchEncryptor.SealedPayload sealed = WorkbenchEncryptor.seal(
            "secret".getBytes(StandardCharsets.UTF_8),
            ProtectionMode.BYOK, fixedDek(), null, null);
        byte[] wrong = new byte[32];
        assertThrows(RuntimeException.class, () ->
            WorkbenchEncryptor.openSealed(
                sealed.ciphertext(), sealed.protection(), wrong, null));
    }

    @Test
    void byokRequires32ByteDek() {
        assertThrows(IllegalArgumentException.class, () ->
            WorkbenchEncryptor.seal("x".getBytes(StandardCharsets.UTF_8),
                ProtectionMode.BYOK, "short".getBytes(StandardCharsets.UTF_8),
                null, null));
    }

    @Test
    void envelopeRequiresKek() {
        assertThrows(IllegalArgumentException.class, () ->
            WorkbenchEncryptor.seal("x".getBytes(StandardCharsets.UTF_8),
                ProtectionMode.ENVELOPE, null, null, null));
    }

    @Test
    void jsonAnchorByok() {
        ProtectionMetadata meta = new ProtectionMetadata(
            "aes-256-gcm", "none", new byte[0], "none", new byte[0]);
        assertEquals(BYOK_ANCHOR_JSON, meta.toJson());
    }

    @Test
    void jsonAnchorSigned() {
        ProtectionMetadata meta = new ProtectionMetadata(
            "aes-256-gcm", "none", new byte[0], "ml-dsa-87",
            new byte[]{0, 1, 2});
        assertEquals(SIGNED_ANCHOR_JSON, meta.toJson());
    }

    @Test
    void jsonRoundTrip() {
        byte[] wrapped = new byte[71];
        byte[] pk = new byte[32];
        new java.security.SecureRandom().nextBytes(wrapped);
        new java.security.SecureRandom().nextBytes(pk);
        ProtectionMetadata meta = new ProtectionMetadata(
            "aes-256-gcm", "aes-256-gcm", wrapped, "none", pk);
        ProtectionMetadata back = ProtectionMetadata.fromJson(meta.toJson());
        assertEquals(meta.cipherSuite, back.cipherSuite);
        assertEquals(meta.kekAlgorithm, back.kekAlgorithm);
        assertArrayEquals(meta.wrappedDek, back.wrappedDek);
        assertEquals(meta.signatureAlgorithm, back.signatureAlgorithm);
        assertArrayEquals(meta.publicKey, back.publicKey);
    }
}
