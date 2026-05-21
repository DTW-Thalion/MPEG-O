/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.pqc;

import global.thalion.ttio.protection.PostQuantumCrypto;

/**
 * Workbench client post-quantum protection (ML-KEM-1024).
 *
 * <p>A thin surface over the core
 * {@link global.thalion.ttio.protection.PostQuantumCrypto}. PQC support
 * is <b>preview-gated</b>: every entry point refuses unless the caller
 * passes {@code preview=true}, mirroring the server's
 * {@code opt_pqc_preview} feature-flag gating (spec Decision 9).</p>
 *
 * <p>The per-AU encrypted-upload path
 * ({@code WorkbenchClient.uploadEncryptedPqc} /
 * {@code downloadDecryptedPqc}) wraps a per-run DEK under an ML-KEM-1024
 * encapsulation public key and carries it in the transport
 * ProtectionMetadata packet. This class supplies the keypair generator
 * and the preview gate that path uses; the wrap/unwrap itself lives in
 * {@link global.thalion.ttio.protection.EncryptionManager}.</p>
 *
 * <p>Cross-language equivalent: Python {@code ttio.workbench.pqc}.</p>
 */
public final class WorkbenchPqc {

    public static final String ML_KEM_1024 = "ml-kem-1024";
    public static final String OPT_PQC_PREVIEW = "opt_pqc_preview";

    private WorkbenchPqc() {}

    /** Raised when a PQC entry point is used without opting into the
     *  preview. Mirrors the server refusing PQC unless
     *  {@code opt_pqc_preview} is set. */
    public static final class PqcPreviewDisabledException extends RuntimeException {
        public PqcPreviewDisabledException(String message) { super(message); }
    }

    /** {@code opt_pqc_preview} gate. Throws
     *  {@link PqcPreviewDisabledException} unless {@code preview} is true. */
    public static void requirePreviewPublic(boolean preview) {
        if (!preview) {
            throw new PqcPreviewDisabledException(
                "PQC client support is behind the '" + OPT_PQC_PREVIEW
                + "' flag; pass preview=true to opt in (matches server "
                + "feature-flag gating).");
        }
    }

    /** Generate an ML-KEM-1024 encapsulation keypair. */
    public static PostQuantumCrypto.KeyPair kemKeygen() {
        return PostQuantumCrypto.kemKeygen();
    }
}
