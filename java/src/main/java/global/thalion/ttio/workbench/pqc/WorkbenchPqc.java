/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.pqc;

import global.thalion.ttio.protection.PostQuantumCrypto;
import global.thalion.ttio.workbench.encryption.ProtectionMetadata;
import global.thalion.ttio.workbench.encryption.ProtectionMode;
import global.thalion.ttio.workbench.encryption.WorkbenchEncryptor;

/**
 * Workbench client post-quantum protection (ML-KEM-1024 + ML-DSA-87).
 *
 * <p>A thin surface over the core
 * {@link global.thalion.ttio.protection.PostQuantumCrypto} and the W6.2
 * {@link WorkbenchEncryptor} envelope path. PQC support is
 * <b>preview-gated</b>: every entry point refuses unless the caller
 * passes {@code preview=true}, mirroring the server's
 * {@code opt_pqc_preview} feature-flag gating (spec Decision 9).</p>
 *
 * <p>Cross-language equivalent: Python {@code ttio.workbench.pqc}. The
 * PQC-envelope {@link ProtectionMetadata} shape
 * ({@code kek_algorithm="ml-kem-1024"} / {@code signature_algorithm=
 * "ml-dsa-87"}) is a cross-language anchor.</p>
 */
public final class WorkbenchPqc {

    public static final String ML_KEM_1024 = "ml-kem-1024";
    public static final String ML_DSA_87 = "ml-dsa-87";
    public static final String OPT_PQC_PREVIEW = "opt_pqc_preview";

    private WorkbenchPqc() {}

    /** Raised when a PQC entry point is used without opting into the
     *  preview. Mirrors the server refusing PQC unless
     *  {@code opt_pqc_preview} is set. */
    public static final class PqcPreviewDisabledException extends RuntimeException {
        public PqcPreviewDisabledException(String message) { super(message); }
    }

    private static void requirePreview(boolean preview) {
        if (!preview) {
            throw new PqcPreviewDisabledException(
                "PQC client support is behind the '" + OPT_PQC_PREVIEW
                + "' flag; pass preview=true to opt in (matches server "
                + "feature-flag gating).");
        }
    }

    /** Public {@code opt_pqc_preview} gate for callers outside this package
     *  (e.g. the per-AU PQC upload path on {@code WorkbenchClient}). Throws
     *  {@link PqcPreviewDisabledException} unless {@code preview} is true. */
    public static void requirePreviewPublic(boolean preview) {
        requirePreview(preview);
    }

    /** Generate an ML-KEM-1024 encapsulation keypair. */
    public static PostQuantumCrypto.KeyPair kemKeygen() {
        return PostQuantumCrypto.kemKeygen();
    }

    /** Generate an ML-DSA-87 signing keypair. */
    public static PostQuantumCrypto.KeyPair sigKeygen() {
        return PostQuantumCrypto.sigKeygen();
    }

    /** A PQC-sealed payload: ciphertext + protection descriptor + the
     *  detached ML-DSA-87 signature (empty when unsigned). */
    public record PqcSealed(byte[] ciphertext, ProtectionMetadata protection,
                             byte[] signature) {}

    /** Seal {@code payload} under an ML-KEM-1024 envelope, unsigned. */
    public static PqcSealed sealPqc(byte[] payload, byte[] recipientKemPublicKey,
                                     boolean preview) {
        return sealPqc(payload, recipientKemPublicKey, preview, null, null);
    }

    /** Seal {@code payload} under an ML-KEM-1024 envelope.
     *  {@code recipientKemPublicKey} is the 1568-byte encapsulation key.
     *  When {@code signerPrivateKey} is non-null the sealed ciphertext is
     *  signed with ML-DSA-87 and the detached signature is returned;
     *  pass {@code signerPublicKey} to record it in the metadata. */
    public static PqcSealed sealPqc(byte[] payload, byte[] recipientKemPublicKey,
                                     boolean preview, byte[] signerPrivateKey,
                                     byte[] signerPublicKey) {
        requirePreview(preview);
        WorkbenchEncryptor.SealedPayload sealed = WorkbenchEncryptor.seal(
            payload, ProtectionMode.ENVELOPE, null, recipientKemPublicKey,
            ML_KEM_1024);
        byte[] signature = new byte[0];
        String signatureAlgorithm = "none";
        byte[] publicKey = new byte[0];
        if (signerPrivateKey != null) {
            signature = PostQuantumCrypto.sigSign(signerPrivateKey, sealed.ciphertext());
            signatureAlgorithm = ML_DSA_87;
            publicKey = signerPublicKey == null ? new byte[0] : signerPublicKey;
        }
        ProtectionMetadata meta = new ProtectionMetadata(
            sealed.protection().cipherSuite, ML_KEM_1024,
            sealed.protection().wrappedDek, signatureAlgorithm, publicKey);
        return new PqcSealed(sealed.ciphertext(), meta, signature);
    }

    /** Decapsulate + decrypt a PQC-sealed payload with the recipient's
     *  ML-KEM-1024 private key (3168 bytes). */
    public static byte[] openPqc(byte[] ciphertext, ProtectionMetadata protection,
                                  byte[] recipientKemPrivateKey, boolean preview) {
        requirePreview(preview);
        return WorkbenchEncryptor.openSealed(
            ciphertext, protection, null, recipientKemPrivateKey);
    }

    /** Verify the ML-DSA-87 signature over a PQC-sealed ciphertext. */
    public static boolean verifyPqc(byte[] ciphertext, byte[] signature,
                                      byte[] signerPublicKey) {
        return PostQuantumCrypto.sigVerify(signerPublicKey, ciphertext, signature);
    }
}
