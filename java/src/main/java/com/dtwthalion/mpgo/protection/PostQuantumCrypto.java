/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo.protection;

import java.security.SecureRandom;
import org.bouncycastle.crypto.AsymmetricCipherKeyPair;
import org.bouncycastle.crypto.SecretWithEncapsulation;
import org.bouncycastle.pqc.crypto.mldsa.MLDSAKeyGenerationParameters;
import org.bouncycastle.pqc.crypto.mldsa.MLDSAKeyPairGenerator;
import org.bouncycastle.pqc.crypto.mldsa.MLDSAParameters;
import org.bouncycastle.pqc.crypto.mldsa.MLDSAPrivateKeyParameters;
import org.bouncycastle.pqc.crypto.mldsa.MLDSAPublicKeyParameters;
import org.bouncycastle.pqc.crypto.mldsa.MLDSASigner;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMGenerator;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyGenerationParameters;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyPairGenerator;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMParameters;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPrivateKeyParameters;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPublicKeyParameters;
import org.bouncycastle.pqc.crypto.mlkem.MLKEMExtractor;

/**
 * Post-quantum crypto primitives — ML-KEM-1024 (FIPS 203) and
 * ML-DSA-87 (FIPS 204).
 *
 * <p>Thin wrapper over Bouncy Castle's low-level PQC API. The same
 * shape as the Python {@code mpeg_o.pqc} module and the Objective-C
 * {@code MPGOCipherSuite} PQC helpers — callers that target multiple
 * languages see the same role map (encapsulate ↔ decapsulate, sign ↔
 * verify).</p>
 *
 * <p><b>Why Bouncy Castle and not liboqs?</b> liboqs's Java bindings
 * require JNI shim builds that are brittle across platforms (Windows
 * MSYS2 vs Linux vs macOS). Bouncy Castle 1.79+ ships production-
 * quality PQC natively in pure Java, is already on Maven Central, and
 * is used throughout the JVM ecosystem. Python and Objective-C get
 * liboqs instead because it ships a stable C API and has formally-
 * verified ML-KEM via PQCP's mlkem-native. See {@code docs/pqc.md} for
 * the detailed cross-language discrepancy table.</p>
 *
 * <p><b>API status:</b> Provisional (v0.8). Subject to breaking
 * changes through the v0.8 series; will be marked Stable at v1.0.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code mpeg_o.pqc}, Objective-C {@code MPGOCipherSuite+PQC} category.</p>
 *
 * @since 0.8
 */
public final class PostQuantumCrypto {

    private static final SecureRandom RNG = new SecureRandom();

    private PostQuantumCrypto() {}

    /** Immutable raw-bytes keypair. */
    public record KeyPair(byte[] publicKey, byte[] privateKey) {}

    /** Encapsulation result: KEM ciphertext and the shared secret. */
    public record KemEncapResult(byte[] ciphertext, byte[] sharedSecret) {}

    // --------------------------------------------- ML-KEM-1024 (FIPS 203) ---

    /**
     * Generate a fresh ML-KEM-1024 encapsulation keypair.
     *
     * @return {@code KeyPair} with {@code publicKey.length == 1568}
     *         and {@code privateKey.length == 3168}.
     */
    public static KeyPair kemKeygen() {
        MLKEMKeyPairGenerator kpg = new MLKEMKeyPairGenerator();
        kpg.init(new MLKEMKeyGenerationParameters(RNG, MLKEMParameters.ml_kem_1024));
        AsymmetricCipherKeyPair kp = kpg.generateKeyPair();
        byte[] pk = ((MLKEMPublicKeyParameters) kp.getPublic()).getEncoded();
        byte[] sk = ((MLKEMPrivateKeyParameters) kp.getPrivate()).getEncoded();
        return new KeyPair(pk, sk);
    }

    /**
     * Encapsulate a fresh 32-byte shared secret under {@code publicKey}.
     *
     * @return {@code KemEncapResult} with a 1568-byte ciphertext and a
     *         32-byte shared secret (AES-256 width by construction).
     */
    public static KemEncapResult kemEncapsulate(byte[] publicKey) {
        MLKEMPublicKeyParameters pk = new MLKEMPublicKeyParameters(
                MLKEMParameters.ml_kem_1024, publicKey);
        MLKEMGenerator gen = new MLKEMGenerator(RNG);
        SecretWithEncapsulation swe = gen.generateEncapsulated(pk);
        byte[] ss = swe.getSecret();
        byte[] ct = swe.getEncapsulation();
        return new KemEncapResult(ct, ss);
    }

    /**
     * Recover the shared secret from a KEM ciphertext using
     * {@code privateKey}. Returns 32 bytes. ML-KEM decapsulation is
     * <i>unauthenticated</i> — a corrupted ciphertext yields a
     * well-formed but meaningless shared secret; downstream AES-GCM
     * unwrap authenticates the chain.
     */
    public static byte[] kemDecapsulate(byte[] privateKey, byte[] ciphertext) {
        MLKEMPrivateKeyParameters sk = new MLKEMPrivateKeyParameters(
                MLKEMParameters.ml_kem_1024, privateKey);
        MLKEMExtractor ex = new MLKEMExtractor(sk);
        return ex.extractSecret(ciphertext);
    }

    // --------------------------------------------- ML-DSA-87 (FIPS 204) ---

    /**
     * Generate a fresh ML-DSA-87 signing keypair.
     *
     * @return {@code KeyPair} with {@code publicKey.length == 2592}
     *         and {@code privateKey.length == 4896}.
     */
    public static KeyPair sigKeygen() {
        MLDSAKeyPairGenerator kpg = new MLDSAKeyPairGenerator();
        kpg.init(new MLDSAKeyGenerationParameters(RNG, MLDSAParameters.ml_dsa_87));
        AsymmetricCipherKeyPair kp = kpg.generateKeyPair();
        byte[] pk = ((MLDSAPublicKeyParameters) kp.getPublic()).getEncoded();
        byte[] sk = ((MLDSAPrivateKeyParameters) kp.getPrivate()).getEncoded();
        return new KeyPair(pk, sk);
    }

    /**
     * Sign {@code message} with the given ML-DSA-87 signing key.
     * Returns 4627 bytes of raw signature.
     */
    public static byte[] sigSign(byte[] privateKey, byte[] message) {
        MLDSAPrivateKeyParameters sk = new MLDSAPrivateKeyParameters(
                MLDSAParameters.ml_dsa_87, privateKey);
        MLDSASigner signer = new MLDSASigner();
        signer.init(true, sk);
        signer.update(message, 0, message.length);
        try {
            return signer.generateSignature();
        } catch (org.bouncycastle.crypto.CryptoException e) {
            throw new RuntimeException("ML-DSA-87 sign failed", e);
        }
    }

    /**
     * Verify an ML-DSA-87 signature on {@code message} under
     * {@code publicKey}. Returns {@code true} on success, {@code false}
     * on a well-formed but invalid signature.
     */
    public static boolean sigVerify(byte[] publicKey, byte[] message,
                                    byte[] signature) {
        MLDSAPublicKeyParameters pk = new MLDSAPublicKeyParameters(
                MLDSAParameters.ml_dsa_87, publicKey);
        MLDSASigner verifier = new MLDSASigner();
        verifier.init(false, pk);
        verifier.update(message, 0, message.length);
        return verifier.verifySignature(signature);
    }
}
