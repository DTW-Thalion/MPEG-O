/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
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

                // Write wrapped DEK as UINT32 array (: default
                // wrap is the v1.2 versioned blob, 71 bytes for AES-GCM,
                // padded with zero bytes to the next 4-byte boundary).
                // Legacy v1.1 (60 bytes → 15 int32) still readable; the
                // length attribute disambiguates.
                byte[] wrapped = EncryptionManager.wrapKey(dek, currentKek);
                int padded = ((wrapped.length + 3) / 4) * 4;
                byte[] padBuf = new byte[padded];
                System.arraycopy(wrapped, 0, padBuf, 0, wrapped.length);
                int[] wrappedInts = new int[padded / 4];
                java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(padBuf);
                bb.order(java.nio.ByteOrder.LITTLE_ENDIAN);
                for (int i = 0; i < wrappedInts.length; i++) {
                    wrappedInts[i] = bb.getInt();
                }

                ki.setIntegerAttribute("dek_wrapped_bytes", wrapped.length);
                try (Hdf5Dataset ds = ki.createDataset("dek_wrapped",
                        Precision.INT32, wrappedInts.length, 0, 0)) {
                    ds.writeData(wrappedInts);
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

            // Read wrapped DEK. v0.7 files carry @dek_wrapped_bytes
            // (actual blob length, dispatch v1.1 vs v1.2). Pre-v0.7
            // files lack that attribute and are always exactly 60
            // bytes (v1.1 AES-256-GCM).
            try (Hdf5Dataset ds = ki.openDataset("dek_wrapped")) {
                int[] wrappedInts = (int[]) ds.readData();
                byte[] padded = new byte[wrappedInts.length * 4];
                java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(padded);
                bb.order(java.nio.ByteOrder.LITTLE_ENDIAN);
                for (int v : wrappedInts) bb.putInt(v);
                long declaredLen = ki.readIntegerAttribute(
                        "dek_wrapped_bytes", 60L);
                byte[] wrapped = java.util.Arrays.copyOfRange(padded, 0,
                        (int) declaredLen);
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
