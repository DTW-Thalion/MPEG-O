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

    // --------------------------------------------------------- file ops

    /**
     * Encrypt the intensity_values dataset of the named MS run inside the
     * {@code .mpgo} file at {@code filePath}, in place.
     *
     * <p>Locates {@code /study/ms_runs/<runName>/signal_channels/}, reads
     * the plaintext {@code intensity_values} dataset, encrypts its bytes
     * with AES-256-GCM, writes {@code intensity_values_encrypted} (byte
     * array packed as int32 padded to 4-byte boundary), plus sibling
     * {@code intensity_iv} and {@code intensity_tag} datasets, plus
     * attributes {@code intensity_ciphertext_bytes} (int64),
     * {@code intensity_original_count} (int64), and
     * {@code intensity_algorithm} ("AES-256-GCM"), then deletes the
     * original {@code intensity_values} dataset.</p>
     *
     * <p>Idempotent: if the channel is already encrypted, returns
     * silently without re-encrypting.</p>
     *
     * @param filePath absolute path to the .mpgo file
     * @param runName  run key under /study/ms_runs/
     * @param key      32-byte AES-256 key
     */
    public static void encryptIntensityChannelInRun(String filePath, String runName, byte[] key) {
        try (com.dtwthalion.mpgo.hdf5.Hdf5File f =
                     com.dtwthalion.mpgo.hdf5.Hdf5File.open(filePath);
             com.dtwthalion.mpgo.hdf5.Hdf5Group root = f.rootGroup();
             com.dtwthalion.mpgo.hdf5.Hdf5Group study = root.openGroup("study");
             com.dtwthalion.mpgo.hdf5.Hdf5Group msRuns = study.openGroup("ms_runs");
             com.dtwthalion.mpgo.hdf5.Hdf5Group runGroup = msRuns.openGroup(runName);
             com.dtwthalion.mpgo.hdf5.Hdf5Group sig = runGroup.openGroup("signal_channels")) {

            // Idempotent: already encrypted
            if (sig.hasChild("intensity_values_encrypted")) return;

            // Read plaintext intensity_values
            double[] data;
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds = sig.openDataset("intensity_values")) {
                data = (double[]) ds.readData();
            }

            // Encrypt
            EncryptResult er = encryptChannel(data, key);
            byte[] ciphertext = er.ciphertext();
            byte[] iv = er.iv();    // 12 bytes
            byte[] tag = er.tag();  // 16 bytes

            // Pad ciphertext to 4-byte boundary, pack as int[]
            int paddedLen = (ciphertext.length + 3) & ~3;
            byte[] padded = Arrays.copyOf(ciphertext, paddedLen);
            int[] cipherInts = bytesToInts(padded);

            // Pack iv (12 bytes → 3 ints) and tag (16 bytes → 4 ints)
            int[] ivInts = bytesToInts(iv);      // exactly 3
            int[] tagInts = bytesToInts(tag);    // exactly 4

            // Write encrypted datasets (no chunking/compression for small crypto blobs)
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_values_encrypted",
                                 com.dtwthalion.mpgo.Enums.Precision.INT32,
                                 cipherInts.length, 0, 0)) {
                ds.writeData(cipherInts);
            }
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_iv",
                                 com.dtwthalion.mpgo.Enums.Precision.INT32,
                                 ivInts.length, 0, 0)) {
                ds.writeData(ivInts);
            }
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_tag",
                                 com.dtwthalion.mpgo.Enums.Precision.INT32,
                                 tagInts.length, 0, 0)) {
                ds.writeData(tagInts);
            }

            // Write attributes
            sig.setIntegerAttribute("intensity_ciphertext_bytes", ciphertext.length);
            sig.setIntegerAttribute("intensity_original_count", data.length);
            sig.setStringAttribute("intensity_algorithm", "AES-256-GCM");

            // Delete the plaintext dataset
            sig.deleteChild("intensity_values");
        }
    }

    /**
     * Decrypt the previously-encrypted intensity channel for the named run.
     * Returns plaintext bytes (length = original_count * 8 for float64).
     * The on-disk file is NOT modified.
     *
     * @param filePath absolute path to the .mpgo file
     * @param runName  run key
     * @param key      32-byte AES-256 key
     * @return plaintext bytes
     */
    public static byte[] decryptIntensityChannelInRun(String filePath, String runName, byte[] key) {
        try (com.dtwthalion.mpgo.hdf5.Hdf5File f =
                     com.dtwthalion.mpgo.hdf5.Hdf5File.openReadOnly(filePath);
             com.dtwthalion.mpgo.hdf5.Hdf5Group root = f.rootGroup();
             com.dtwthalion.mpgo.hdf5.Hdf5Group study = root.openGroup("study");
             com.dtwthalion.mpgo.hdf5.Hdf5Group msRuns = study.openGroup("ms_runs");
             com.dtwthalion.mpgo.hdf5.Hdf5Group runGroup = msRuns.openGroup(runName);
             com.dtwthalion.mpgo.hdf5.Hdf5Group sig = runGroup.openGroup("signal_channels")) {

            // Read ciphertext_bytes attribute
            long ciphertextBytes = sig.readIntegerAttribute("intensity_ciphertext_bytes", -1);
            if (ciphertextBytes < 0) {
                throw new IllegalStateException(
                        "intensity_ciphertext_bytes attribute missing; is channel encrypted?");
            }

            // Read encrypted int32 datasets
            int[] cipherInts;
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds =
                         sig.openDataset("intensity_values_encrypted")) {
                cipherInts = (int[]) ds.readData();
            }
            int[] ivInts;
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds = sig.openDataset("intensity_iv")) {
                ivInts = (int[]) ds.readData();
            }
            int[] tagInts;
            try (com.dtwthalion.mpgo.hdf5.Hdf5Dataset ds = sig.openDataset("intensity_tag")) {
                tagInts = (int[]) ds.readData();
            }

            // Unpack
            byte[] ciphertextPadded = intsToBytes(cipherInts);
            byte[] ciphertext = Arrays.copyOf(ciphertextPadded, (int) ciphertextBytes);
            byte[] iv = intsToBytes(ivInts);
            byte[] tag = intsToBytes(tagInts);

            return decrypt(ciphertext, iv, tag, key);
        }
    }

    // ------------------------------------------------------------ helpers

    private static void validateKey(byte[] key) {
        if (key == null || key.length != KEY_BYTES) {
            throw new IllegalArgumentException("Key must be exactly 32 bytes");
        }
    }

    /** Pack bytes (length must be multiple of 4) into little-endian int[]. */
    private static int[] bytesToInts(byte[] bytes) {
        int n = (bytes.length + 3) / 4;
        byte[] padded = bytes.length % 4 == 0 ? bytes : Arrays.copyOf(bytes, n * 4);
        int[] ints = new int[n];
        ByteBuffer buf = ByteBuffer.wrap(padded).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < n; i++) ints[i] = buf.getInt();
        return ints;
    }

    /** Unpack little-endian int[] to bytes. */
    private static byte[] intsToBytes(int[] ints) {
        ByteBuffer buf = ByteBuffer.allocate(ints.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int v : ints) buf.putInt(v);
        return buf.array();
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
