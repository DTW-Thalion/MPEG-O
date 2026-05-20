/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.encryption;

import global.thalion.ttio.protection.EncryptionManager;

import java.security.SecureRandom;
import java.util.Arrays;

/**
 * Workbench client-side payload protection (BYOK / envelope).
 *
 * <p>A thin wrapper over the core
 * {@link global.thalion.ttio.protection.EncryptionManager} that seals a
 * {@code .tis} payload for an encrypted upload and produces the matching
 * {@link ProtectionMetadata}.</p>
 *
 * <ul>
 *   <li><b>BYOK</b> -- the researcher brings a 32-byte DEK; the key never
 *       leaves the client, so {@code wrappedDek} is empty.</li>
 *   <li><b>ENVELOPE</b> -- a fresh random DEK seals the payload and is
 *       wrapped under a KEK via the core v1.2 wrap (AES-256-GCM, or
 *       ML-KEM-1024 -- the latter is W6.3/PQC territory).</li>
 * </ul>
 *
 * <p>Sealed-payload framing (both languages): {@code iv(12) || tag(16) ||
 * ciphertext}. Cross-language equivalent: Python
 * {@code ttio.workbench.encryption}.</p>
 */
public final class WorkbenchEncryptor {

    private static final int IV_BYTES = 12;
    private static final int TAG_BYTES = 16;
    private static final int KEY_BYTES = 32;
    private static final String DEFAULT_CIPHER_SUITE = "aes-256-gcm";
    private static final String DEFAULT_KEK_ALGORITHM = "aes-256-gcm";
    private static final SecureRandom RNG = new SecureRandom();

    private WorkbenchEncryptor() {}

    /** A sealed upload payload plus its protection descriptor. */
    public record SealedPayload(byte[] ciphertext, ProtectionMetadata protection) {}

    /** Seal {@code payload}. BYOK: pass {@code dek} (32 bytes), {@code kek}
     *  null. ENVELOPE: pass {@code kek}, {@code dek} null. */
    public static SealedPayload seal(byte[] payload, ProtectionMode mode,
                                       byte[] dek, byte[] kek,
                                       String kekAlgorithm) {
        switch (mode) {
            case BYOK -> {
                if (dek == null || dek.length != KEY_BYTES) {
                    throw new IllegalArgumentException("BYOK requires a 32-byte dek");
                }
                EncryptionManager.EncryptResult er =
                    EncryptionManager.encrypt(payload, dek);
                ProtectionMetadata meta = new ProtectionMetadata(
                    DEFAULT_CIPHER_SUITE, "none", new byte[0], "none", new byte[0]);
                return new SealedPayload(frame(er), meta);
            }
            case ENVELOPE -> {
                if (kek == null) {
                    throw new IllegalArgumentException("ENVELOPE requires a kek");
                }
                String alg = kekAlgorithm == null ? DEFAULT_KEK_ALGORITHM : kekAlgorithm;
                byte[] freshDek = new byte[KEY_BYTES];
                RNG.nextBytes(freshDek);
                EncryptionManager.EncryptResult er =
                    EncryptionManager.encrypt(payload, freshDek);
                byte[] wrapped = EncryptionManager.wrapKey(freshDek, kek, false, alg);
                ProtectionMetadata meta = new ProtectionMetadata(
                    DEFAULT_CIPHER_SUITE, alg, wrapped, "none", new byte[0]);
                return new SealedPayload(frame(er), meta);
            }
            default -> throw new IllegalArgumentException("unsupported mode: " + mode);
        }
    }

    /** BYOK convenience. */
    public static SealedPayload sealByok(byte[] payload, byte[] dek) {
        return seal(payload, ProtectionMode.BYOK, dek, null, null);
    }

    /** Envelope convenience (AES-256-GCM KEK). */
    public static SealedPayload sealEnvelope(byte[] payload, byte[] kek) {
        return seal(payload, ProtectionMode.ENVELOPE, null, kek, DEFAULT_KEK_ALGORITHM);
    }

    /** Reverse {@link #seal}. BYOK (empty {@code wrappedDek}): pass the
     *  same {@code dek}. ENVELOPE: pass the {@code kek} that unwraps
     *  {@code protection.wrappedDek}. */
    public static byte[] openSealed(byte[] ciphertext, ProtectionMetadata protection,
                                      byte[] dek, byte[] kek) {
        if (ciphertext.length < IV_BYTES + TAG_BYTES) {
            throw new IllegalArgumentException("sealed payload too short");
        }
        byte[] iv = Arrays.copyOfRange(ciphertext, 0, IV_BYTES);
        byte[] tag = Arrays.copyOfRange(ciphertext, IV_BYTES, IV_BYTES + TAG_BYTES);
        byte[] ct = Arrays.copyOfRange(ciphertext, IV_BYTES + TAG_BYTES, ciphertext.length);
        byte[] key;
        if (protection.wrappedDek != null && protection.wrappedDek.length > 0) {
            if (kek == null) {
                throw new IllegalArgumentException("envelope payload requires a kek to unwrap");
            }
            key = EncryptionManager.unwrapKey(protection.wrappedDek, kek);
        } else {
            if (dek == null) {
                throw new IllegalArgumentException("BYOK payload requires the dek");
            }
            key = dek;
        }
        return EncryptionManager.decrypt(ct, iv, tag, key);
    }

    private static byte[] frame(EncryptionManager.EncryptResult er) {
        byte[] out = new byte[IV_BYTES + TAG_BYTES + er.ciphertext().length];
        System.arraycopy(er.iv(), 0, out, 0, IV_BYTES);
        System.arraycopy(er.tag(), 0, out, IV_BYTES, TAG_BYTES);
        System.arraycopy(er.ciphertext(), 0, out,
                         IV_BYTES + TAG_BYTES, er.ciphertext().length);
        return out;
    }
}
