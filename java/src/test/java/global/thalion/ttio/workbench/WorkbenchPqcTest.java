/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.protection.PostQuantumCrypto;
import global.thalion.ttio.workbench.pqc.WorkbenchPqc;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * W6.3 -- workbench PQC client surface (ML-KEM-1024).
 *
 * <p>The blob {@code sealPqc} / {@code openPqc} envelope path was removed
 * with the per-AU encrypted-upload rework (it was never daemon-
 * compatible). What remains is the preview gate + keypair generator that
 * the per-AU PQC upload path ({@code WorkbenchClient.uploadEncryptedPqc})
 * uses; the gate's end-to-end behaviour is covered by the live smoke
 * ({@code WorkbenchLiveTest.perAuEncryptedPqcUploadRoundTrip}). Mirrors
 * the Python {@code test_pqc.py}.</p>
 */
class WorkbenchPqcTest {

    @Test
    void requirePreviewRefusesWithoutOptIn() {
        assertThrows(WorkbenchPqc.PqcPreviewDisabledException.class,
            () -> WorkbenchPqc.requirePreviewPublic(false));
    }

    @Test
    void requirePreviewPassesWhenOptIn() {
        WorkbenchPqc.requirePreviewPublic(true);  // no throw
    }

    @Test
    void kemKeygenShapes() {
        PostQuantumCrypto.KeyPair kp = WorkbenchPqc.kemKeygen();
        assertEquals(1568, kp.publicKey().length);
        assertEquals(3168, kp.privateKey().length);
    }

    @Test
    void mlKem1024Constant() {
        assertEquals("ml-kem-1024", WorkbenchPqc.ML_KEM_1024);
    }
}
