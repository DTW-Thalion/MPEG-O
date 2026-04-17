/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo.protection;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * HMAC-SHA256 signatures with v2 canonical little-endian format for MPEG-O datasets.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOSignatureManager}, Python {@code mpeg_o.signatures}.</p>
 *
 * @since 0.6
 */
public final class SignatureManager {

    private static final String HMAC_ALGORITHM = "HmacSHA256";
    private static final int KEY_BYTES = 32;
    private static final String V2_PREFIX = "v2:";

    private SignatureManager() {}

    // -------------------------------------------------------------- sign / verify

    /**
     * Sign a byte array.
     *
     * @param data bytes to sign
     * @param key  32-byte HMAC key
     * @return signature string in the form {@code "v2:" + base64(hmac)}
     */
    public static String sign(byte[] data, byte[] key) {
        byte[] mac = hmac(data, key);
        return V2_PREFIX + Base64.getEncoder().encodeToString(mac);
    }

    /**
     * Verify a signature string against data and key.
     * Handles both {@code "v2:"}-prefixed signatures and unprefixed v1 signatures.
     *
     * @param data      original bytes
     * @param signature signature string to verify
     * @param key       32-byte HMAC key
     * @return {@code true} if the signature is valid
     */
    public static boolean verify(byte[] data, String signature, byte[] key) {
        byte[] expected = hmac(data, key);
        byte[] actual;
        if (signature.startsWith(V2_PREFIX)) {
            actual = Base64.getDecoder().decode(signature.substring(V2_PREFIX.length()));
        } else {
            // v1 compatibility: treat entire string as base64-encoded HMAC
            actual = Base64.getDecoder().decode(signature);
        }
        return MessageDigest.isEqual(expected, actual);
    }

    // ----------------------------------------------------------------- hmac

    /**
     * Compute raw HMAC-SHA256 bytes.
     *
     * @param data bytes to authenticate
     * @param key  32-byte HMAC key
     * @return 32-byte HMAC digest
     */
    public static byte[] hmac(byte[] data, byte[] key) {
        try {
            Mac mac = Mac.getInstance(HMAC_ALGORITHM);
            mac.init(new SecretKeySpec(key, HMAC_ALGORITHM));
            return mac.doFinal(data);
        } catch (GeneralSecurityException e) {
            throw new RuntimeException("HMAC-SHA256 computation failed", e);
        }
    }

    // -------------------------------------------------------- canonicalisation

    /**
     * Canonicalise a {@code double[]} to little-endian bytes for signing.
     *
     * @param data signal samples
     * @return little-endian byte representation
     */
    public static byte[] canonicalBytes(double[] data) {
        ByteBuffer buf = ByteBuffer.allocate(data.length * Double.BYTES)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (double v : data) {
            buf.putDouble(v);
        }
        return buf.array();
    }

    /**
     * Canonicalise an {@code int[]} to little-endian bytes for signing.
     *
     * @param data integer samples
     * @return little-endian byte representation
     */
    public static byte[] canonicalBytes(int[] data) {
        ByteBuffer buf = ByteBuffer.allocate(data.length * Integer.BYTES)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (int v : data) {
            buf.putInt(v);
        }
        return buf.array();
    }

    /**
     * Canonicalise a {@code long[]} to little-endian bytes for signing.
     *
     * @param data long samples
     * @return little-endian byte representation
     */
    public static byte[] canonicalBytes(long[] data) {
        ByteBuffer buf = ByteBuffer.allocate(data.length * Long.BYTES)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (long v : data) {
            buf.putLong(v);
        }
        return buf.array();
    }

    /**
     * Canonicalise a variable-length string for compound signing.
     * Format: {@code uint32_le(len) || utf8_bytes}. A {@code null} string
     * produces a 4-byte zero-length prefix with no payload.
     *
     * @param s string to canonicalise (may be {@code null})
     * @return canonical byte representation
     */
    public static byte[] canonicalStringBytes(String s) {
        byte[] utf8 = (s != null) ? s.getBytes(StandardCharsets.UTF_8) : new byte[0];
        ByteBuffer buf = ByteBuffer.allocate(Integer.BYTES + utf8.length)
                .order(ByteOrder.LITTLE_ENDIAN);
        buf.putInt(utf8.length);
        buf.put(utf8);
        return buf.array();
    }

    // ------------------------------------------------------------ test key

    /**
     * Canonical signature test key: {@code key[i] = (byte)((0x5A ^ (i * 7)) & 0xFF)}
     * for i in [0,32).
     *
     * @return 32-byte deterministic test key
     */
    public static byte[] testKey() {
        byte[] key = new byte[KEY_BYTES];
        for (int i = 0; i < KEY_BYTES; i++) {
            key[i] = (byte) ((0x5A ^ (i * 7)) & 0xFF);
        }
        return key;
    }
}
