/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.7 M48 — CipherSuite catalog + algorithm= parameter plumbing.
 *
 *
 */
class CipherSuiteTest {

    @Test
    void activeDefaultsAreRegistered() {
        assertTrue(CipherSuite.isSupported("aes-256-gcm"));
        assertTrue(CipherSuite.isSupported("hmac-sha256"));
        assertTrue(CipherSuite.isSupported("sha-256"));
    }

    @Test
    void reservedEntriesRegisteredButNotSupported() {
        // After v0.8 M49, only shake256 is still reserved.
        assertTrue(CipherSuite.isRegistered("shake256"));
        assertFalse(CipherSuite.isSupported("shake256"),
                "shake256 must still be reserved");
        // ml-kem-1024 and ml-dsa-87 became active in M49.
        assertTrue(CipherSuite.isSupported("ml-kem-1024"),
                "ml-kem-1024 must be active after M49");
        assertTrue(CipherSuite.isSupported("ml-dsa-87"),
                "ml-dsa-87 must be active after M49");
    }

    @Test
    void unknownAlgorithmIsNotInCatalog() {
        assertFalse(CipherSuite.isRegistered("chacha20-poly1305"));
        assertFalse(CipherSuite.isSupported("garbage"));
    }

    @Test
    void aes256GcmMetadata() {
        assertEquals(CipherSuite.Category.AEAD,
                CipherSuite.category("aes-256-gcm"));
        assertEquals(32, CipherSuite.keyLength("aes-256-gcm"));
        assertEquals(12, CipherSuite.nonceLength("aes-256-gcm"));
        assertEquals(16, CipherSuite.tagLength("aes-256-gcm"));
    }

    @Test
    void hmacSha256MetadataIndicatesVariableKey() {
        assertEquals(CipherSuite.Category.MAC,
                CipherSuite.category("hmac-sha256"));
        assertEquals(-1, CipherSuite.keyLength("hmac-sha256"),
                "HMAC key length is variable, represented as -1");
        assertEquals(32, CipherSuite.tagLength("hmac-sha256"));
    }

    @Test
    void validateKeyAes256GcmAcceptsExactly32Bytes() {
        CipherSuite.validateKey("aes-256-gcm", new byte[32]);
    }

    @Test
    void validateKeyAes256GcmRejectsWrongLength() {
        for (int len : new int[]{0, 1, 16, 31, 33, 64}) {
            final int l = len;
            assertThrows(CipherSuite.InvalidKeyException.class,
                    () -> CipherSuite.validateKey("aes-256-gcm", new byte[l]),
                    "length=" + l + " should be rejected");
        }
    }

    @Test
    void validateKeyHmacSha256AcceptsAnyNonemptyKey() {
        CipherSuite.validateKey("hmac-sha256", new byte[]{'k'});
        CipherSuite.validateKey("hmac-sha256", new byte[32]);
        CipherSuite.validateKey("hmac-sha256", new byte[100]);
    }

    @Test
    void validateKeyHmacSha256RejectsEmptyKey() {
        assertThrows(CipherSuite.InvalidKeyException.class,
                () -> CipherSuite.validateKey("hmac-sha256", new byte[0]));
    }

    @Test
    void validateKeyReservedAlgorithmRaises() {
        // shake256 remains reserved in v0.8.
        CipherSuite.UnsupportedAlgorithmException thrown = assertThrows(
                CipherSuite.UnsupportedAlgorithmException.class,
                () -> CipherSuite.validateKey("shake256", new byte[32]));
        assertTrue(thrown.getMessage().contains("RESERVED"));
    }

    @Test
    void validateKeyRejectsAsymmetricAlgorithms() {
        // validateKey is symmetric-only — asymmetric entries must route
        // through validatePublicKey / validatePrivateKey.
        assertThrows(CipherSuite.InvalidKeyException.class,
                () -> CipherSuite.validateKey("ml-kem-1024", new byte[32]));
        assertThrows(CipherSuite.InvalidKeyException.class,
                () -> CipherSuite.validateKey("ml-dsa-87", new byte[32]));
    }

    @Test
    void validateKeyUnknownAlgorithmRaises() {
        assertThrows(CipherSuite.UnsupportedAlgorithmException.class,
                () -> CipherSuite.validateKey("garbage", new byte[32]));
    }

    // ── Integration: encrypt/decrypt via the algorithm= parameter ──

    @Test
    void encryptWithExplicitAlgorithmDefaultsPreserved() {
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) 0xAB);
        EncryptionManager.EncryptResult er =
                EncryptionManager.encrypt("hello".getBytes(), key,
                                            "aes-256-gcm");
        byte[] pt = EncryptionManager.decrypt(er.ciphertext(), er.iv(),
                er.tag(), key, "aes-256-gcm");
        assertArrayEquals("hello".getBytes(), pt);
    }

    @Test
    void encryptRejectsAsymmetricAlgorithm() {
        // ml-kem-1024 is KEM (not AEAD); encrypt must refuse it via
        // validateKey's asymmetric-rejection guard.
        byte[] key = new byte[32];
        assertThrows(RuntimeException.class,
                () -> EncryptionManager.encrypt("hello".getBytes(), key,
                                                  "ml-kem-1024"));
    }

    @Test
    void wrapKeyAcceptsAlgorithmParameter() {
        byte[] kek = new byte[32];
        byte[] dek = new byte[32];
        java.util.Arrays.fill(kek, (byte) 0x11);
        java.util.Arrays.fill(dek, (byte) 0x22);
        byte[] wrapped = EncryptionManager.wrapKey(dek, kek, /*legacyV1*/false,
                "aes-256-gcm");
        byte[] unwrapped = EncryptionManager.unwrapKey(wrapped, kek);
        assertArrayEquals(dek, unwrapped);
    }
}
