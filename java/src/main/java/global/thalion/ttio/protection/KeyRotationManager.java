/* TTI-O Java Implementation / Copyright (c) 2026 The Thalion Initiative / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio.protection;

import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.hdf5.*;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.*;

/**
 * Envelope encryption and key rotation for TTI-O datasets.
 *
 * <p>A Data Encryption Key (DEK) encrypts signal payloads; a Key Encryption
 * Key (KEK) wraps the DEK with AES-256-GCM. Rotation re-wraps the DEK
 * under a new KEK without touching any signal dataset, so it is O(1) in
 * file size.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOKeyRotationManager}, Python {@code ttio.key_rotation}.</p>
 *
 *
 */
public class KeyRotationManager {

    private byte[] dek;       // 32-byte data encryption key
    private byte[] currentKek; // current key-encryption key
    private String kekId;
    private final List<Map<String, String>> keyHistory = new ArrayList<>();

    /** Enable envelope encryption with a new random DEK wrapped by the given KEK. */
    public void enableEnvelopeEncryption(byte[] kek, String kekId) {
        this.currentKek = kek.clone();
        this.kekId = kekId;
        this.dek = new byte[32];
        new SecureRandom().nextBytes(this.dek);
    }

    /** Get the DEK for encrypting/decrypting data. */
    public byte[] getDek() { return dek; }

    /** Rotate: unwrap DEK with old KEK, re-wrap with new KEK. */
    public void rotateKey(byte[] newKek, String newKekId) {
        // Record old KEK in history
        Map<String, String> entry = new LinkedHashMap<>();
        entry.put("timestamp", Instant.now().toString());
        entry.put("kek_id", this.kekId);
        entry.put("kek_algorithm", "aes-256-gcm");
        keyHistory.add(entry);

        // Re-wrap DEK with new KEK
        this.currentKek = newKek.clone();
        this.kekId = newKekId;
    }

    /** Write key info to /protection/key_info/ group under root. */
    public void writeTo(Hdf5Group rootGroup) {
        Hdf5Group prot;
        if (rootGroup.hasChild("protection")) {
            prot = rootGroup.openGroup("protection");
        } else {
            prot = rootGroup.createGroup("protection");
        }
        try (prot) {
            Hdf5Group ki;
            if (prot.hasChild("key_info")) {
                prot.deleteChild("key_info");
            }
            ki = prot.createGroup("key_info");
            try (ki) {
                ki.setStringAttribute("kek_id", kekId);
                ki.setStringAttribute("kek_algorithm", "aes-256-gcm");
                ki.setStringAttribute("wrapped_at", Instant.now().toString());
                ki.setStringAttribute("key_history_json", historyToJson());

                // Write wrapped DEK as a uint8[N] dataset holding the
                // EXACT wrapped bytes — no padding, no int32 packing. This
                // is the spec-compliant layout (docs/format-spec.md §5b)
                // shared by Python and ObjC, so files round-trip across
                // languages. The blob length is also recorded in the
                // @dek_wrapped_bytes attribute for forward clarity; it
                // equals the dataset's byte length.
                byte[] wrapped = EncryptionManager.wrapKey(dek, currentKek);

                ki.setIntegerAttribute("dek_wrapped_bytes", wrapped.length);
                try (Hdf5Dataset ds = ki.createDataset("dek_wrapped",
                        Precision.UINT8, wrapped.length, 0, 0)) {
                    ds.writeData(wrapped);
                }
            }
        }
    }

    /** Read key info from /protection/key_info/ and unwrap DEK with given KEK. */
    public static KeyRotationManager readFrom(Hdf5Group rootGroup, byte[] kek) {
        KeyRotationManager mgr = new KeyRotationManager();
        try (Hdf5Group prot = rootGroup.openGroup("protection");
             Hdf5Group ki = prot.openGroup("key_info")) {
            mgr.kekId = ki.readStringAttribute("kek_id");
            mgr.currentKek = kek.clone();

            // Read wrapped DEK, dispatching on the on-disk dataset
            // precision recovered by openDataset():
            //   - UINT8 (spec-compliant; Python/ObjC and current Java):
            //     the dataset holds the exact wrapped bytes verbatim. The
            //     true length is the dataset's byte length, which equals
            //     @dek_wrapped_bytes when present.
            //   - INT32 (legacy Java files already on disk): bytes were
            //     little-endian int32-packed and zero-padded to a 4-byte
            //     boundary; reassemble and slice to @dek_wrapped_bytes.
            // When @dek_wrapped_bytes is absent we fall back to the
            // dataset's actual byte length (60 for true v1.1 legacy files,
            // and correct for uint8 blobs of any size).
            try (Hdf5Dataset ds = ki.openDataset("dek_wrapped")) {
                byte[] wrapped;
                if (ds.getPrecision() == Precision.UINT8) {
                    byte[] raw = (byte[]) ds.readData();
                    long declaredLen = ki.readIntegerAttribute(
                            "dek_wrapped_bytes", raw.length);
                    int len = (int) declaredLen;
                    if (len < 0 || len > raw.length) len = raw.length;
                    wrapped = (len == raw.length)
                            ? raw
                            : java.util.Arrays.copyOfRange(raw, 0, len);
                } else {
                    // Legacy INT32-packed Java layout.
                    int[] wrappedInts = (int[]) ds.readData();
                    byte[] padded = new byte[wrappedInts.length * 4];
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(padded);
                    bb.order(java.nio.ByteOrder.LITTLE_ENDIAN);
                    for (int v : wrappedInts) bb.putInt(v);
                    long declaredLen = ki.readIntegerAttribute(
                            "dek_wrapped_bytes", padded.length);
                    wrapped = java.util.Arrays.copyOfRange(padded, 0,
                            (int) declaredLen);
                }
                mgr.dek = EncryptionManager.unwrapKey(wrapped, kek);
            }

            if (ki.hasAttribute("key_history_json")) {
                // Parse history (simple, not critical for functionality)
                String json = ki.readStringAttribute("key_history_json");
                // Minimal parse - store raw for now
            }
        }
        return mgr;
    }

    private String historyToJson() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < keyHistory.size(); i++) {
            if (i > 0) sb.append(",");
            Map<String, String> e = keyHistory.get(i);
            sb.append("{");
            boolean first = true;
            for (var entry : e.entrySet()) {
                if (!first) sb.append(",");
                sb.append("\"").append(entry.getKey()).append("\":\"")
                  .append(entry.getValue()).append("\"");
                first = false;
            }
            sb.append("}");
        }
        sb.append("]");
        return sb.toString();
    }
}
