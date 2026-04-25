/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio.protection;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * AES-256-GCM encryption/decryption for TTI-O datasets.
 *
 * <p>Key parameters: 32-byte key, 12-byte random IV, 128-bit (16-byte) authentication tag.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOEncryptionManager}, Python {@code ttio.encryption}.</p>
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
     * Encrypt plaintext bytes with AES-256-GCM (default cipher suite).
     * Shorthand for {@link #encrypt(byte[], byte[], String)} with
     * {@code algorithm="aes-256-gcm"}.
     *
     * @param plaintext data to encrypt
     * @param key       32-byte AES-256 key
     * @return EncryptResult containing ciphertext, iv, and tag
     */
    public static EncryptResult encrypt(byte[] plaintext, byte[] key) {
        return encrypt(plaintext, key, "aes-256-gcm");
    }

    /**
     * Encrypt plaintext bytes with the named cipher suite. v0.7 M48:
     * algorithm selection is routed through {@link CipherSuite}.
     * Only {@code "aes-256-gcm"} is active in v0.7; reserved suites
     * raise {@link CipherSuite.UnsupportedAlgorithmException}.
     *
     * @since 0.7
     */
    public static EncryptResult encrypt(byte[] plaintext, byte[] key,
                                         String algorithm) {
        CipherSuite.validateKey(algorithm, key);
        if (!"aes-256-gcm".equals(algorithm)) {
            throw new CipherSuite.UnsupportedAlgorithmException(
                algorithm + ": AEAD path not yet implemented");
        }
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
     * Decrypt ciphertext given iv and tag (AES-256-GCM default).
     * Shorthand for {@link #decrypt(byte[], byte[], byte[], byte[], String)}.
     *
     * @param ciphertext encrypted bytes (without tag)
     * @param iv         12-byte initialisation vector
     * @param tag        16-byte authentication tag
     * @param key        32-byte AES-256 key
     * @return plaintext bytes
     */
    public static byte[] decrypt(byte[] ciphertext, byte[] iv, byte[] tag, byte[] key) {
        return decrypt(ciphertext, iv, tag, key, "aes-256-gcm");
    }

    /**
     * Decrypt with the named cipher suite. v0.7 M48: algorithm
     * selection via {@link CipherSuite}.
     *
     * @since 0.7
     */
    public static byte[] decrypt(byte[] ciphertext, byte[] iv, byte[] tag,
                                   byte[] key, String algorithm) {
        CipherSuite.validateKey(algorithm, key);
        if (!"aes-256-gcm".equals(algorithm)) {
            throw new CipherSuite.UnsupportedAlgorithmException(
                algorithm + ": AEAD path not yet implemented");
        }
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
    //
    // v0.7 M47: versioned wrapped-key blob format v1.2.
    //
    //   +0   2  magic       = 0x4D 0x57 ("MW" — TTIO Wrap)
    //   +2   1  version     = 0x02
    //   +3   2  algorithm_id (big-endian)
    //               0x0000 = AES-256-GCM
    //               0x0001 = ML-KEM-1024  (reserved, M49)
    //   +5   4  ciphertext_len (big-endian)
    //   +9   2  metadata_len   (big-endian)
    //  +11   M  metadata  (AES-GCM: IV ‖ tag, M=28)
    //  +11+M C  ciphertext
    //
    // Readers dispatch on blob length: exactly 60 bytes ⇒ v1.1 legacy,
    // anything else ⇒ v1.2. Binding decision 38: v1.1 remains readable
    // indefinitely.

    private static final byte[] WK_MAGIC = { 'M', 'W' };
    private static final byte WK_VERSION_V2 = 0x02;
    private static final int WK_ALG_AES_256_GCM = 0x0000;
    /** v0.8 M49: ML-KEM-1024 envelope. Writes set the
     *  {@code opt_pqc_preview} feature flag on the enclosing file. */
    public static final int WK_ALG_ML_KEM_1024 = 0x0001;
    private static final int WK_HEADER_LEN = 11;
    private static final int V11_BLOB_LEN = KEY_BYTES + IV_BYTES + TAG_BYTES; // 60

    /** ML-KEM-1024 ciphertext length (FIPS 203). @since 0.8 */
    public static final int MLKEM_CT_LEN = 1568;
    /** ML-KEM envelope metadata = kem_ct || aes_iv || aes_tag. @since 0.8 */
    public static final int MLKEM_METADATA_LEN =
            MLKEM_CT_LEN + IV_BYTES + TAG_BYTES;  // 1596
    /** Total on-disk ML-KEM wrapped-key blob size. @since 0.8 */
    public static final int MLKEM_BLOB_LEN =
            WK_HEADER_LEN + MLKEM_METADATA_LEN + KEY_BYTES;  // 1639

    /**
     * Wrap a data-encryption key (DEK) with a key-encryption key (KEK).
     * Emits the v1.2 versioned AES-256-GCM blob (71 bytes).
     *
     * @param dek 32-byte data-encryption key
     * @param kek 32-byte key-encryption key
     * @return v1.2 wrapped blob (71 bytes for AES-256-GCM).
     */
    public static byte[] wrapKey(byte[] dek, byte[] kek) {
        return wrapKey(dek, kek, /* legacyV1= */ false);
    }

    /**
     * Wrap a DEK with an explicit version selector.
     * @param legacyV1 when {@code true}, emits the 60-byte v1.1 layout
     *                 for regression fixtures; callers targeting
     *                 production should use {@link #wrapKey(byte[], byte[])}.
     * @since 0.7
     */
    public static byte[] wrapKey(byte[] dek, byte[] kek, boolean legacyV1) {
        return wrapKey(dek, kek, legacyV1, "aes-256-gcm");
    }

    /**
     * Wrap a DEK with an explicit version selector and cipher suite.
     * v0.8 M49: adds {@code algorithm="ml-kem-1024"} for post-quantum
     * key encapsulation. {@code kek} is interpreted per algorithm —
     * 32-byte symmetric for AES-GCM, 1568-byte ML-KEM public key for
     * ML-KEM.
     *
     * @since 0.7
     */
    public static byte[] wrapKey(byte[] dek, byte[] kek, boolean legacyV1,
                                   String algorithm) {
        // DEK is always symmetric AES-256 (HANDOFF binding #43).
        CipherSuite.validateKey("aes-256-gcm", dek);

        if ("aes-256-gcm".equals(algorithm)) {
            CipherSuite.validateKey(algorithm, kek);
            EncryptResult er = encrypt(dek, kek, algorithm);
            if (legacyV1) {
                byte[] blob = new byte[V11_BLOB_LEN];
                System.arraycopy(er.ciphertext(), 0, blob, 0, KEY_BYTES);
                System.arraycopy(er.iv(), 0, blob, KEY_BYTES, IV_BYTES);
                System.arraycopy(er.tag(), 0, blob, KEY_BYTES + IV_BYTES, TAG_BYTES);
                return blob;
            }
            byte[] metadata = new byte[IV_BYTES + TAG_BYTES];
            System.arraycopy(er.iv(), 0, metadata, 0, IV_BYTES);
            System.arraycopy(er.tag(), 0, metadata, IV_BYTES, TAG_BYTES);
            return packBlobV2(WK_ALG_AES_256_GCM, er.ciphertext(), metadata);
        }

        if ("ml-kem-1024".equals(algorithm)) {
            if (legacyV1) {
                throw new IllegalArgumentException(
                    "v1.1 legacy layout is AES-256-GCM only; refusing "
                    + "to emit v1.1 for algorithm=\"ml-kem-1024\"");
            }
            CipherSuite.validatePublicKey(algorithm, kek);
            PostQuantumCrypto.KemEncapResult r =
                    PostQuantumCrypto.kemEncapsulate(kek);
            // Shared secret is 32 bytes (AES-256 width) — wrap the DEK
            // under it with AES-256-GCM.
            EncryptResult er = encrypt(dek, r.sharedSecret(), "aes-256-gcm");
            byte[] metadata = new byte[MLKEM_METADATA_LEN];
            System.arraycopy(r.ciphertext(), 0, metadata, 0, MLKEM_CT_LEN);
            System.arraycopy(er.iv(), 0, metadata, MLKEM_CT_LEN, IV_BYTES);
            System.arraycopy(er.tag(), 0, metadata,
                    MLKEM_CT_LEN + IV_BYTES, TAG_BYTES);
            return packBlobV2(WK_ALG_ML_KEM_1024, er.ciphertext(), metadata);
        }

        throw new CipherSuite.UnsupportedAlgorithmException(
            algorithm + ": wrap path not implemented");
    }

    /**
     * Unwrap a DEK from a wrapped-key blob with an explicit cipher
     * suite selector. Distinct from the blob-length-dispatched
     * {@link #unwrapKey(byte[], byte[])} to support ML-KEM-1024
     * (where the reader must already know it's holding the
     * decapsulation private key, not a symmetric AES KEK).
     *
     * @since 0.8
     */
    public static byte[] unwrapKey(byte[] wrappedBlob, byte[] kek,
                                    String algorithm) {
        if ("aes-256-gcm".equals(algorithm)) {
            CipherSuite.validateKey(algorithm, kek);
            return unwrapKey(wrappedBlob, kek);
        }
        if ("ml-kem-1024".equals(algorithm)) {
            CipherSuite.validatePrivateKey(algorithm, kek);
            WrappedBlobV2 parsed = unpackBlobV2(wrappedBlob);
            if (parsed.algorithmId() != WK_ALG_ML_KEM_1024) {
                throw new IllegalArgumentException(
                    "expected ML-KEM-1024 algorithm_id=0x0001, got "
                    + String.format("0x%04X", parsed.algorithmId()));
            }
            if (parsed.metadata().length != MLKEM_METADATA_LEN) {
                throw new IllegalArgumentException(
                    "ML-KEM-1024 metadata must be " + MLKEM_METADATA_LEN
                    + " bytes (kem_ct || iv || tag); got "
                    + parsed.metadata().length);
            }
            if (parsed.ciphertext().length != KEY_BYTES) {
                throw new IllegalArgumentException(
                    "ML-KEM-1024 wrapped DEK must be " + KEY_BYTES
                    + " bytes; got " + parsed.ciphertext().length);
            }
            byte[] kemCt = Arrays.copyOfRange(parsed.metadata(),
                    0, MLKEM_CT_LEN);
            byte[] iv = Arrays.copyOfRange(parsed.metadata(),
                    MLKEM_CT_LEN, MLKEM_CT_LEN + IV_BYTES);
            byte[] tag = Arrays.copyOfRange(parsed.metadata(),
                    MLKEM_CT_LEN + IV_BYTES, MLKEM_METADATA_LEN);
            byte[] sharedSecret = PostQuantumCrypto.kemDecapsulate(kek, kemCt);
            return decrypt(parsed.ciphertext(), iv, tag, sharedSecret,
                    "aes-256-gcm");
        }
        throw new CipherSuite.UnsupportedAlgorithmException(
            algorithm + ": unwrap path not implemented");
    }

    /**
     * Pack a v1.2 wrapped-key blob. Public for cross-language interop
     * tests (M51) and for algorithm-specific wrappers introduced in M48.
     * @since 0.7
     */
    public static byte[] packBlobV2(int algorithmId, byte[] ciphertext,
                                    byte[] metadata) {
        if (ciphertext.length < 0 || ciphertext.length > 0x7FFFFFFF) {
            throw new IllegalArgumentException("ciphertext too large");
        }
        if (metadata.length > 0xFFFF) {
            throw new IllegalArgumentException("metadata > 64 KB");
        }
        byte[] out = new byte[WK_HEADER_LEN + metadata.length + ciphertext.length];
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(out)
                .order(java.nio.ByteOrder.BIG_ENDIAN);
        bb.put(WK_MAGIC);
        bb.put(WK_VERSION_V2);
        bb.putShort((short) (algorithmId & 0xFFFF));
        bb.putInt(ciphertext.length);
        bb.putShort((short) (metadata.length & 0xFFFF));
        bb.put(metadata);
        bb.put(ciphertext);
        return out;
    }

    /** Parsed v1.2 wrapped-key blob fields. @since 0.7 */
    public record WrappedBlobV2(int algorithmId, byte[] metadata,
                                 byte[] ciphertext) {}

    /**
     * Unpack a v1.2 wrapped-key blob.
     * @throws IllegalArgumentException if the magic or layout is malformed.
     * @since 0.7
     */
    public static WrappedBlobV2 unpackBlobV2(byte[] blob) {
        if (blob.length < WK_HEADER_LEN) {
            throw new IllegalArgumentException(
                    "v1.2 wrapped-key blob too short: " + blob.length);
        }
        if (blob[0] != WK_MAGIC[0] || blob[1] != WK_MAGIC[1]) {
            throw new IllegalArgumentException(
                    "v1.2 wrapped-key blob: bad magic");
        }
        if (blob[2] != WK_VERSION_V2) {
            throw new IllegalArgumentException(
                    "v1.2 wrapped-key blob: unknown version "
                    + (blob[2] & 0xFF));
        }
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(blob, 3, 8)
                .order(java.nio.ByteOrder.BIG_ENDIAN);
        int algorithmId = bb.getShort() & 0xFFFF;
        int ctLen = bb.getInt();
        int mdLen = bb.getShort() & 0xFFFF;
        if (blob.length != WK_HEADER_LEN + mdLen + ctLen) {
            throw new IllegalArgumentException(
                    "v1.2 wrapped-key blob length mismatch: header declares "
                    + "metadata=" + mdLen + " ciphertext=" + ctLen
                    + " but payload is " + (blob.length - WK_HEADER_LEN)
                    + " bytes");
        }
        byte[] metadata = Arrays.copyOfRange(blob, WK_HEADER_LEN,
                WK_HEADER_LEN + mdLen);
        byte[] ciphertext = Arrays.copyOfRange(blob, WK_HEADER_LEN + mdLen,
                blob.length);
        return new WrappedBlobV2(algorithmId, metadata, ciphertext);
    }

    /**
     * Unwrap a DEK from a wrapped-key blob. Dispatches on blob length:
     * exactly 60 bytes ⇒ v1.1 legacy; anything else ⇒ v1.2 versioned.
     *
     * @param wrappedBlob the blob produced by {@link #wrapKey}.
     * @param kek 32-byte key-encryption key.
     * @return 32-byte DEK.
     * @throws IllegalArgumentException if the blob uses a reserved
     *         algorithm id (e.g. ML-KEM-1024 without the {@code pqc_preview}
     *         build profile enabled in M49).
     */
    public static byte[] unwrapKey(byte[] wrappedBlob, byte[] kek) {
        if (wrappedBlob.length == V11_BLOB_LEN) {
            // v1.1 legacy path.
            byte[] ciphertext = Arrays.copyOfRange(wrappedBlob, 0, KEY_BYTES);
            byte[] iv = Arrays.copyOfRange(wrappedBlob, KEY_BYTES,
                    KEY_BYTES + IV_BYTES);
            byte[] tag = Arrays.copyOfRange(wrappedBlob, KEY_BYTES + IV_BYTES,
                    KEY_BYTES + IV_BYTES + TAG_BYTES);
            return decrypt(ciphertext, iv, tag, kek);
        }
        WrappedBlobV2 parsed = unpackBlobV2(wrappedBlob);
        if (parsed.algorithmId() != WK_ALG_AES_256_GCM) {
            throw new IllegalArgumentException(
                    "v1.2 wrapped-key blob uses algorithm_id="
                    + String.format("0x%04X", parsed.algorithmId())
                    + " which this build does not support "
                    + "(enable 'pqc_preview' for ML-KEM-1024 in M49+)");
        }
        if (parsed.metadata().length != IV_BYTES + TAG_BYTES) {
            throw new IllegalArgumentException(
                    "v1.2 AES-GCM metadata must be 28 bytes; got "
                    + parsed.metadata().length);
        }
        if (parsed.ciphertext().length != KEY_BYTES) {
            throw new IllegalArgumentException(
                    "v1.2 AES-GCM ciphertext must be 32 bytes; got "
                    + parsed.ciphertext().length);
        }
        byte[] iv = Arrays.copyOfRange(parsed.metadata(), 0, IV_BYTES);
        byte[] tag = Arrays.copyOfRange(parsed.metadata(), IV_BYTES,
                IV_BYTES + TAG_BYTES);
        return decrypt(parsed.ciphertext(), iv, tag, kek);
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
     * {@code .tio} file at {@code filePath}, in place.
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
     * @param filePath absolute path to the .tio file
     * @param runName  run key under /study/ms_runs/
     * @param key      32-byte AES-256 key
     */
    public static void encryptIntensityChannelInRun(String filePath, String runName, byte[] key) {
        try (global.thalion.ttio.hdf5.Hdf5File f =
                     global.thalion.ttio.hdf5.Hdf5File.open(filePath);
             global.thalion.ttio.hdf5.Hdf5Group root = f.rootGroup();
             global.thalion.ttio.hdf5.Hdf5Group study = root.openGroup("study");
             global.thalion.ttio.hdf5.Hdf5Group msRuns = study.openGroup("ms_runs");
             global.thalion.ttio.hdf5.Hdf5Group runGroup = msRuns.openGroup(runName);
             global.thalion.ttio.hdf5.Hdf5Group sig = runGroup.openGroup("signal_channels")) {

            // Idempotent: already encrypted
            if (sig.hasChild("intensity_values_encrypted")) return;

            // Read plaintext intensity_values
            double[] data;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds = sig.openDataset("intensity_values")) {
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
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_values_encrypted",
                                 global.thalion.ttio.Enums.Precision.INT32,
                                 cipherInts.length, 0, 0)) {
                ds.writeData(cipherInts);
            }
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_iv",
                                 global.thalion.ttio.Enums.Precision.INT32,
                                 ivInts.length, 0, 0)) {
                ds.writeData(ivInts);
            }
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_tag",
                                 global.thalion.ttio.Enums.Precision.INT32,
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
     * @param filePath absolute path to the .tio file
     * @param runName  run key
     * @param key      32-byte AES-256 key
     * @return plaintext bytes
     */
    public static byte[] decryptIntensityChannelInRun(String filePath, String runName, byte[] key) {
        try (global.thalion.ttio.hdf5.Hdf5File f =
                     global.thalion.ttio.hdf5.Hdf5File.openReadOnly(filePath);
             global.thalion.ttio.hdf5.Hdf5Group root = f.rootGroup();
             global.thalion.ttio.hdf5.Hdf5Group study = root.openGroup("study");
             global.thalion.ttio.hdf5.Hdf5Group msRuns = study.openGroup("ms_runs");
             global.thalion.ttio.hdf5.Hdf5Group runGroup = msRuns.openGroup(runName);
             global.thalion.ttio.hdf5.Hdf5Group sig = runGroup.openGroup("signal_channels")) {

            // Read ciphertext_bytes attribute
            long ciphertextBytes = sig.readIntegerAttribute("intensity_ciphertext_bytes", -1);
            if (ciphertextBytes < 0) {
                throw new IllegalStateException(
                        "intensity_ciphertext_bytes attribute missing; is channel encrypted?");
            }

            // Read encrypted int32 datasets
            int[] cipherInts;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.openDataset("intensity_values_encrypted")) {
                cipherInts = (int[]) ds.readData();
            }
            int[] ivInts;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds = sig.openDataset("intensity_iv")) {
                ivInts = (int[]) ds.readData();
            }
            int[] tagInts;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds = sig.openDataset("intensity_tag")) {
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

    /**
     * v1.1.1: persist-to-disk decrypt counterpart to
     * {@link #encryptIntensityChannelInRun}. Opens the {@code .tio} file
     * read-write, decrypts the named run's {@code intensity_values_encrypted}
     * dataset, writes plaintext back as a new {@code intensity_values}
     * float64 dataset, deletes the encrypted siblings
     * ({@code intensity_values_encrypted}, {@code intensity_iv},
     * {@code intensity_tag}), and removes the channel-level attributes
     * {@code intensity_ciphertext_bytes}, {@code intensity_original_count},
     * and {@code intensity_algorithm}. The root {@code @encrypted}
     * attribute is left in place — callers that want a fully unprotected
     * file should use
     * {@link global.thalion.ttio.SpectralDataset#decryptInPlace(String, byte[])}.
     *
     * <p>Idempotent: returns silently if the run is already plaintext.</p>
     *
     * @param filePath absolute path to the .tio file
     * @param runName  run key under /study/ms_runs/
     * @param key      32-byte AES-256 key
     */
    public static void decryptIntensityChannelInRunInPlace(String filePath,
                                                            String runName,
                                                            byte[] key) {
        validateKey(key);
        try (global.thalion.ttio.hdf5.Hdf5File f =
                     global.thalion.ttio.hdf5.Hdf5File.open(filePath);
             global.thalion.ttio.hdf5.Hdf5Group root = f.rootGroup();
             global.thalion.ttio.hdf5.Hdf5Group study = root.openGroup("study");
             global.thalion.ttio.hdf5.Hdf5Group msRuns = study.openGroup("ms_runs");
             global.thalion.ttio.hdf5.Hdf5Group runGroup = msRuns.openGroup(runName);
             global.thalion.ttio.hdf5.Hdf5Group sig = runGroup.openGroup("signal_channels")) {

            // Idempotent: already plaintext.
            if (!sig.hasChild("intensity_values_encrypted")) return;

            long ciphertextBytes =
                    sig.readIntegerAttribute("intensity_ciphertext_bytes", -1);
            if (ciphertextBytes < 0) {
                throw new IllegalStateException(
                        "intensity_values_encrypted present but "
                                + "intensity_ciphertext_bytes missing in run '"
                                + runName + "'");
            }
            long originalCount =
                    sig.readIntegerAttribute("intensity_original_count", -1);
            if (originalCount < 0) {
                throw new IllegalStateException(
                        "intensity_values_encrypted present but "
                                + "intensity_original_count missing in run '"
                                + runName + "'");
            }

            int[] cipherInts;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.openDataset("intensity_values_encrypted")) {
                cipherInts = (int[]) ds.readData();
            }
            int[] ivInts;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.openDataset("intensity_iv")) {
                ivInts = (int[]) ds.readData();
            }
            int[] tagInts;
            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.openDataset("intensity_tag")) {
                tagInts = (int[]) ds.readData();
            }

            byte[] ciphertextPadded = intsToBytes(cipherInts);
            byte[] ciphertext =
                    Arrays.copyOf(ciphertextPadded, (int) ciphertextBytes);
            byte[] iv = Arrays.copyOf(intsToBytes(ivInts), IV_BYTES);
            byte[] tag = Arrays.copyOf(intsToBytes(tagInts), TAG_BYTES);

            byte[] plaintextBytes = decrypt(ciphertext, iv, tag, key);
            if (plaintextBytes.length != originalCount * Double.BYTES) {
                throw new IllegalStateException(
                        "decrypted plaintext length " + plaintextBytes.length
                                + " does not match intensity_original_count*8 ("
                                + (originalCount * Double.BYTES) + ")");
            }
            double[] plaintext =
                    leBytesToDoubles(plaintextBytes, (int) originalCount);

            sig.deleteChild("intensity_values_encrypted");
            sig.deleteChild("intensity_iv");
            sig.deleteChild("intensity_tag");
            sig.deleteAttribute("intensity_ciphertext_bytes");
            sig.deleteAttribute("intensity_original_count");
            sig.deleteAttribute("intensity_algorithm");

            try (global.thalion.ttio.hdf5.Hdf5Dataset ds =
                         sig.createDataset("intensity_values",
                                 global.thalion.ttio.Enums.Precision.FLOAT64,
                                 plaintext.length, 0, 0)) {
                ds.writeData(plaintext);
            }
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
