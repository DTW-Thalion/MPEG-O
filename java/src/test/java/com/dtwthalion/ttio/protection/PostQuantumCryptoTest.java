/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.ttio.protection;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dtwthalion.ttio.protection.CipherSuite.InvalidKeyException;
import com.dtwthalion.ttio.protection.CipherSuite.UnsupportedAlgorithmException;
import com.dtwthalion.ttio.protection.EncryptionManager.WrappedBlobV2;
import com.dtwthalion.ttio.protection.PostQuantumCrypto.KemEncapResult;
import com.dtwthalion.ttio.protection.PostQuantumCrypto.KeyPair;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.junit.jupiter.api.Test;

/**
 * Milestone 49 — Post-quantum crypto (Java side, Bouncy Castle).
 *
 * <p>Covers the PostQuantumCrypto wrapper, CipherSuite activation of
 * ML-KEM-1024 / ML-DSA-87, v3 signature path in SignatureManager, and
 * the ML-KEM-1024 envelope path in EncryptionManager.</p>
 */
public class PostQuantumCryptoTest {

    // ----------------------------------------------- ML-KEM primitives ---

    @Test
    public void mlKemKeygenSizes() {
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        assertEquals(1568, kp.publicKey().length);
        assertEquals(3168, kp.privateKey().length);
    }

    @Test
    public void mlKemEncapDecapRoundTrip() {
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        KemEncapResult r = PostQuantumCrypto.kemEncapsulate(kp.publicKey());
        assertEquals(1568, r.ciphertext().length);
        assertEquals(32, r.sharedSecret().length);
        byte[] recovered = PostQuantumCrypto.kemDecapsulate(
                kp.privateKey(), r.ciphertext());
        assertArrayEquals(r.sharedSecret(), recovered);
    }

    // ----------------------------------------------- ML-DSA primitives ---

    @Test
    public void mlDsaKeygenSizes() {
        KeyPair kp = PostQuantumCrypto.sigKeygen();
        assertEquals(2592, kp.publicKey().length);
        assertEquals(4896, kp.privateKey().length);
    }

    @Test
    public void mlDsaSignVerifyRoundTrip() {
        KeyPair kp = PostQuantumCrypto.sigKeygen();
        byte[] msg = "the quick brown fox".getBytes(StandardCharsets.UTF_8);
        byte[] sig = PostQuantumCrypto.sigSign(kp.privateKey(), msg);
        assertEquals(4627, sig.length);
        assertTrue(PostQuantumCrypto.sigVerify(kp.publicKey(), msg, sig));
        // Tamper message
        byte[] tampered = Arrays.copyOf(msg, msg.length);
        tampered[0] ^= 0x01;
        assertFalse(PostQuantumCrypto.sigVerify(kp.publicKey(), tampered, sig));
        // Tamper signature
        byte[] badSig = Arrays.copyOf(sig, sig.length);
        badSig[0] ^= 0x01;
        assertFalse(PostQuantumCrypto.sigVerify(kp.publicKey(), msg, badSig));
    }

    // --------------------------------------------- CipherSuite integration ---

    @Test
    public void catalogPqcActive() {
        assertTrue(CipherSuite.isSupported("ml-kem-1024"));
        assertTrue(CipherSuite.isSupported("ml-dsa-87"));
        assertEquals(1568, CipherSuite.publicKeySize("ml-kem-1024"));
        assertEquals(3168, CipherSuite.privateKeySize("ml-kem-1024"));
        assertEquals(2592, CipherSuite.publicKeySize("ml-dsa-87"));
        assertEquals(4896, CipherSuite.privateKeySize("ml-dsa-87"));
    }

    @Test
    public void validateKeyRejectsAsymmetric() {
        assertThrows(InvalidKeyException.class, () ->
                CipherSuite.validateKey("ml-kem-1024", new byte[1568]));
        assertThrows(InvalidKeyException.class, () ->
                CipherSuite.validateKey("ml-dsa-87", new byte[4896]));
    }

    @Test
    public void validatePublicPrivateRolesSwapped() {
        // Correct sizes: no-op.
        CipherSuite.validatePublicKey("ml-kem-1024", new byte[1568]);
        CipherSuite.validatePrivateKey("ml-kem-1024", new byte[3168]);
        // Swapped: must fail.
        assertThrows(InvalidKeyException.class, () ->
                CipherSuite.validatePublicKey("ml-kem-1024", new byte[3168]));
        assertThrows(InvalidKeyException.class, () ->
                CipherSuite.validatePrivateKey("ml-kem-1024", new byte[1568]));
    }

    // ---------------------------------------------- v3 signatures ---

    @Test
    public void v3SignVerifyRoundTrip() {
        KeyPair kp = PostQuantumCrypto.sigKeygen();
        byte[] data = "hello from java".getBytes(StandardCharsets.UTF_8);
        String stored = SignatureManager.sign(data, kp.privateKey(), "ml-dsa-87");
        assertTrue(stored.startsWith(SignatureManager.V3_PREFIX));
        assertTrue(SignatureManager.verify(data, stored, kp.publicKey(),
                "ml-dsa-87"));
    }

    @Test
    public void v3VerifyRejectsTamperedData() {
        KeyPair kp = PostQuantumCrypto.sigKeygen();
        byte[] data = "original".getBytes(StandardCharsets.UTF_8);
        String stored = SignatureManager.sign(data, kp.privateKey(), "ml-dsa-87");
        byte[] tampered = "tampered".getBytes(StandardCharsets.UTF_8);
        assertFalse(SignatureManager.verify(tampered, stored, kp.publicKey(),
                "ml-dsa-87"));
    }

    @Test
    public void verifyAlgorithmMismatchRaises() {
        KeyPair kp = PostQuantumCrypto.sigKeygen();
        byte[] data = "x".getBytes(StandardCharsets.UTF_8);
        String stored = SignatureManager.sign(data, kp.privateKey(), "ml-dsa-87");
        assertThrows(UnsupportedAlgorithmException.class, () ->
                SignatureManager.verify(data, stored, new byte[32],
                        "hmac-sha256"));

        // Reverse: v2 stored, verifier asks for v3.
        byte[] hmacKey = SignatureManager.testKey();
        String v2Stored = SignatureManager.sign(data, hmacKey, "hmac-sha256");
        assertThrows(UnsupportedAlgorithmException.class, () ->
                SignatureManager.verify(data, v2Stored, kp.publicKey(),
                        "ml-dsa-87"));
    }

    @Test
    public void v2BackwardCompatStillWorks() {
        byte[] data = "legacy".getBytes(StandardCharsets.UTF_8);
        byte[] hmacKey = SignatureManager.testKey();
        String stored = SignatureManager.sign(data, hmacKey, "hmac-sha256");
        assertTrue(SignatureManager.verify(data, stored, hmacKey, "hmac-sha256"));
    }

    // ---------------------------------------------- ML-KEM envelope ---

    @Test
    public void mlKemWrapUnwrapRoundTrip() {
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        byte[] dek = new byte[32];
        for (int i = 0; i < 32; i++) dek[i] = (byte) (i ^ 0x5A);

        byte[] wrapped = EncryptionManager.wrapKey(dek, kp.publicKey(),
                /* legacyV1= */ false, "ml-kem-1024");
        assertEquals(EncryptionManager.MLKEM_BLOB_LEN, wrapped.length);

        // Magic + version + algorithm_id header invariants.
        assertEquals('M', wrapped[0]);
        assertEquals('W', wrapped[1]);
        assertEquals(0x02, wrapped[2]);
        assertEquals(0x00, wrapped[3]);
        assertEquals(0x01, wrapped[4]);  // ML-KEM-1024

        byte[] recovered = EncryptionManager.unwrapKey(
                wrapped, kp.privateKey(), "ml-kem-1024");
        assertArrayEquals(dek, recovered);
    }

    @Test
    public void mlKemWrongPrivateKeyFails() {
        KeyPair good = PostQuantumCrypto.kemKeygen();
        KeyPair bad = PostQuantumCrypto.kemKeygen();
        byte[] dek = new byte[32];
        byte[] wrapped = EncryptionManager.wrapKey(dek, good.publicKey(),
                false, "ml-kem-1024");
        // ML-KEM decap with wrong sk yields garbage shared secret →
        // AES-GCM authentication fails.
        assertThrows(RuntimeException.class, () ->
                EncryptionManager.unwrapKey(wrapped, bad.privateKey(),
                        "ml-kem-1024"));
    }

    @Test
    public void mlKemWrapRejectsLegacyV1() {
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        byte[] dek = new byte[32];
        assertThrows(IllegalArgumentException.class, () ->
                EncryptionManager.wrapKey(dek, kp.publicKey(),
                        /* legacyV1= */ true, "ml-kem-1024"));
    }

    @Test
    public void mlKemWrapRejectsWrongKeyShape() {
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        byte[] dek = new byte[32];
        // Passing the private key as the writer-side KEK must fail.
        assertThrows(InvalidKeyException.class, () ->
                EncryptionManager.wrapKey(dek, kp.privateKey(), false,
                        "ml-kem-1024"));
    }

    @Test
    public void mlKemBlobStructurallyParseable() {
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        byte[] dek = new byte[32];
        byte[] blob = EncryptionManager.wrapKey(dek, kp.publicKey(),
                false, "ml-kem-1024");
        WrappedBlobV2 parsed = EncryptionManager.unpackBlobV2(blob);
        assertEquals(EncryptionManager.WK_ALG_ML_KEM_1024, parsed.algorithmId());
        assertEquals(EncryptionManager.MLKEM_METADATA_LEN,
                parsed.metadata().length);
        assertEquals(32, parsed.ciphertext().length);
    }

    @Test
    public void aes256GcmStillWorksAfterPqcActivation() {
        // Regression guard: activating PQC must not break AES-256-GCM wrap.
        byte[] kek = new byte[32];
        byte[] dek = new byte[32];
        for (int i = 0; i < 32; i++) {
            kek[i] = (byte) (i * 7);
            dek[i] = (byte) (i * 13);
        }
        byte[] wrapped = EncryptionManager.wrapKey(dek, kek);
        byte[] recovered = EncryptionManager.unwrapKey(wrapped, kek);
        assertArrayEquals(dek, recovered);
        assertNotEquals(EncryptionManager.MLKEM_BLOB_LEN, wrapped.length);
    }
}
