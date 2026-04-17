/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo.protection;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * AES-256-GCM encryption/decryption for MPEG-O datasets.
 *
 * <p>Key parameters: 32-byte key, 12-byte random IV, 128-bit (16-byte) authentication tag.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOEncryptionManager}, Python {@code mpeg_o.encryption}.</p>
 *
 * @since 0.6
 */
public final class EncryptionManager {

    private static final int KEY_BYTES = 32;
    private static final int IV_BYTES = 12;
    private static final int TAG_BYTES = 16;
    private static final int TAG_BITS = TAG_BYTES * 8;
    private static final String ALGORITHM = "AES/GCM/NoPadding";

    private static final SecureRandom RNG = new SecureRandom();

    private EncryptionManager() {}

    // ------------------------------------------------------------------ types

    /** Result of an encryption operation. */
    public record EncryptResult(byte[] ciphertext, byte[] iv, byte[] tag) {}

    // -------------------------------------------------------------- core ops

    /**
     * Encrypt plaintext bytes.
     *
     * @param plaintext data to encrypt
     * @param key       32-byte AES-256 key
     * @return EncryptResult containing ciphertext, iv, and tag
     */
    public static EncryptResult encrypt(byte[] plaintext, byte[] key) {
        validateKey(key);
        try {
            byte[] iv = new byte[IV_BYTES];
            RNG.nextBytes(iv);

            Cipher cipher = Cipher.getInstance(ALGORITHM);
            cipher.init(Cipher.ENCRYPT_MODE,
                    new SecretKeySpec(key, "AES"),
                    new GCMParameterSpec(TAG_BITS, iv));

            byte[] combined = cipher.doFinal(plaintext);
            // javax.crypto appends the tag to the ciphertext
            byte[] ciphertext = Arrays.copyOfRange(combined, 0, combined.length - TAG_BYTES);
            byte[] tag = Arrays.copyOfRange(combined, combined.length - TAG_BYTES, combined.length);

            return new EncryptResult(ciphertext, iv, tag);
        } catch (GeneralSecurityException e) {
            throw new RuntimeException("AES-256-GCM encryption failed", e);
        }
    }

    /**
     * Decrypt ciphertext given iv and tag.
     *
     * @param ciphertext encrypted bytes (without tag)
     * @param iv         12-byte initialisation vector
     * @param tag        16-byte authentication tag
     * @param key        32-byte AES-256 key
     * @return plaintext bytes
     */
    public static byte[] decrypt(byte[] ciphertext, byte[] iv, byte[] tag, byte[] key) {
        validateKey(key);
        try {
            // Reassemble ciphertext||tag as javax.crypto expects
            byte[] combined = new byte[ciphertext.length + tag.length];
            System.arraycopy(ciphertext, 0, combined, 0, ciphertext.length);
            System.arraycopy(tag, 0, combined, ciphertext.length, tag.length);

            Cipher cipher = Cipher.getInstance(ALGORITHM);
            cipher.init(Cipher.DECRYPT_MODE,
                    new SecretKeySpec(key, "AES"),
                    new GCMParameterSpec(TAG_BITS, iv));

            return cipher.doFinal(combined);
        } catch (GeneralSecurityException e) {
            throw new RuntimeException("AES-256-GCM decryption failed", e);
        }
    }

    // --------------------------------------------------------- channel ops

    /**
     * Encrypt a {@code double[]} signal channel.
     * Serialises to little-endian bytes, then encrypts.
     *
     * @param data signal samples
     * @param key  32-byte AES-256 key
     * @return EncryptResult
     */
    public static EncryptResult encryptChannel(double[] data, byte[] key) {
        byte[] raw = doublesToLeBytes(data);
        return encrypt(raw, key);
    }

    /**
     * Decrypt a signal channel back to {@code double[]}.
     *
     * @param ciphertext    encrypted bytes
     * @param iv            12-byte IV
     * @param tag           16-byte tag
     * @param key           32-byte key
     * @param originalCount number of doubles in the original channel
     * @return decrypted signal samples
     */
    public static double[] decryptChannel(byte[] ciphertext, byte[] iv, byte[] tag,
                                          byte[] key, int originalCount) {
        byte[] raw = decrypt(ciphertext, iv, tag, key);
        return leBytesToDoubles(raw, originalCount);
    }

    // ------------------------------------------------------------ key wrap

    /**
     * Wrap a data-encryption key (DEK) with a key-encryption key (KEK).
     *
     * @param dek 32-byte data-encryption key
     * @param kek 32-byte key-encryption key
     * @return 60-byte blob: ciphertext(32) || iv(12) || tag(16)
     */
    public static byte[] wrapKey(byte[] dek, byte[] kek) {
        if (dek.length != KEY_BYTES) {
            throw new IllegalArgumentException("DEK must be 32 bytes");
        }
        EncryptResult er = encrypt(dek, kek);
        byte[] blob = new byte[KEY_BYTES + IV_BYTES + TAG_BYTES]; // 60
        System.arraycopy(er.ciphertext(), 0, blob, 0, KEY_BYTES);
        System.arraycopy(er.iv(), 0, blob, KEY_BYTES, IV_BYTES);
        System.arraycopy(er.tag(), 0, blob, KEY_BYTES + IV_BYTES, TAG_BYTES);
        return blob;
    }

    /**
     * Unwrap a DEK from a 60-byte blob using a KEK.
     *
     * @param wrappedBlob 60-byte blob produced by {@link #wrapKey}
     * @param kek         32-byte key-encryption key
     * @return 32-byte DEK
     */
    public static byte[] unwrapKey(byte[] wrappedBlob, byte[] kek) {
        if (wrappedBlob.length != KEY_BYTES + IV_BYTES + TAG_BYTES) {
            throw new IllegalArgumentException("Wrapped blob must be 60 bytes");
        }
        byte[] ciphertext = Arrays.copyOfRange(wrappedBlob, 0, KEY_BYTES);
        byte[] iv = Arrays.copyOfRange(wrappedBlob, KEY_BYTES, KEY_BYTES + IV_BYTES);
        byte[] tag = Arrays.copyOfRange(wrappedBlob, KEY_BYTES + IV_BYTES,
                KEY_BYTES + IV_BYTES + TAG_BYTES);
        return decrypt(ciphertext, iv, tag, kek);
    }

    // ------------------------------------------------------------ test key

    /**
     * Canonical test key: {@code key[i] = (byte)((0xA5 ^ (i * 3)) & 0xFF)} for i in [0,32).
     *
     * @return 32-byte deterministic test key
     */
    public static byte[] testKey() {
        byte[] key = new byte[KEY_BYTES];
        for (int i = 0; i < KEY_BYTES; i++) {
            key[i] = (byte) ((0xA5 ^ (i * 3)) & 0xFF);
        }
        return key;
    }

    // ------------------------------------------------------------ helpers

    private static void validateKey(byte[] key) {
        if (key == null || key.length != KEY_BYTES) {
            throw new IllegalArgumentException("Key must be exactly 32 bytes");
        }
    }

    private static byte[] doublesToLeBytes(double[] data) {
        ByteBuffer buf = ByteBuffer.allocate(data.length * Double.BYTES)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (double v : data) {
            buf.putDouble(v);
        }
        return buf.array();
    }

    private static double[] leBytesToDoubles(byte[] raw, int count) {
        ByteBuffer buf = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        double[] result = new double[count];
        for (int i = 0; i < count; i++) {
            result[i] = buf.getDouble();
        }
        return result;
    }
}
