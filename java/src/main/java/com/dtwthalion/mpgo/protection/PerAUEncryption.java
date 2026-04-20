/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo.protection;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * v1.0 per-Access-Unit encryption primitives. Implements
 * {@code opt_per_au_encryption} (channel data) and
 * {@code opt_encrypted_au_headers} (AU semantic header) as specified
 * in {@code docs/transport-encryption-design.md} and
 * {@code docs/format-spec.md} §9.1.
 *
 * <p>Unlike {@link EncryptionManager} — which encrypts an entire
 * channel as one AES-GCM operation — this class generates one AES-GCM
 * operation per spectrum, producing {@link ChannelSegment} rows and
 * optional {@link HeaderSegment} rows.
 *
 * <p>Each AES-GCM op binds its ciphertext to its context via
 * authenticated data: {@code dataset_id (u16 LE) || au_sequence (u32
 * LE) || purpose_tag}, where {@code purpose_tag} is the UTF-8 channel
 * name, the literal bytes {@code "header"}, or the literal bytes
 * {@code "pixel"}.
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code mpeg_o.encryption_per_au}, Objective-C
 * {@code MPGOPerAUEncryption}.
 *
 * @since 1.0
 */
public final class PerAUEncryption {

    public static final int IV_BYTES = 12;
    public static final int TAG_BYTES = 16;
    public static final int KEY_BYTES = 32;
    public static final int HEADER_PLAINTEXT_BYTES = 36;

    private static final int TAG_BITS = TAG_BYTES * 8;
    private static final String GCM_ALGO = "AES/GCM/NoPadding";
    private static final SecureRandom RNG = new SecureRandom();

    private PerAUEncryption() {}

    // ---------------------------------------------------------- AAD

    /** AAD for an encrypted channel: {@code dataset_id || au_sequence
     *  || channel_name_utf8}. */
    public static byte[] aadForChannel(int datasetId, long auSequence,
                                         String channelName) {
        byte[] tag = channelName.getBytes(StandardCharsets.UTF_8);
        return packPrefix(datasetId, auSequence, tag);
    }

    /** AAD for the encrypted AU semantic header. Appends literal
     *  {@code "header"}. */
    public static byte[] aadForHeader(int datasetId, long auSequence) {
        return packPrefix(datasetId, auSequence,
                          "header".getBytes(StandardCharsets.US_ASCII));
    }

    /** AAD for the encrypted MSImagePixel envelope. Appends literal
     *  {@code "pixel"}. */
    public static byte[] aadForPixel(int datasetId, long auSequence) {
        return packPrefix(datasetId, auSequence,
                          "pixel".getBytes(StandardCharsets.US_ASCII));
    }

    private static byte[] packPrefix(int datasetId, long auSequence,
                                        byte[] tail) {
        byte[] out = new byte[6 + tail.length];
        ByteBuffer bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN);
        bb.putShort((short) (datasetId & 0xFFFF));
        bb.putInt((int) (auSequence & 0xFFFFFFFFL));
        System.arraycopy(tail, 0, out, 6, tail.length);
        return out;
    }

    // ------------------------------------------------ Low-level AES-GCM + AAD

    /** Result of a per-AU encryption: (iv, tag, ciphertext). */
    public record GcmResult(byte[] iv, byte[] tag, byte[] ciphertext) {}

    /** AES-256-GCM encrypt with AAD. Generates a fresh random IV when
     *  {@code iv} is {@code null}; deterministic tests pass a fixed IV. */
    public static GcmResult encryptWithAad(byte[] plaintext, byte[] key,
                                             byte[] aad, byte[] iv) {
        requireKey(key);
        byte[] useIv = iv != null ? iv : randomIv();
        if (useIv.length != IV_BYTES) {
            throw new IllegalArgumentException(
                "IV must be " + IV_BYTES + " bytes, got " + useIv.length);
        }
        try {
            Cipher cipher = Cipher.getInstance(GCM_ALGO);
            cipher.init(Cipher.ENCRYPT_MODE,
                        new SecretKeySpec(key, "AES"),
                        new GCMParameterSpec(TAG_BITS, useIv));
            if (aad != null) cipher.updateAAD(aad);
            byte[] combined = cipher.doFinal(plaintext);
            byte[] ct = Arrays.copyOfRange(combined, 0,
                                            combined.length - TAG_BYTES);
            byte[] tag = Arrays.copyOfRange(combined,
                                             combined.length - TAG_BYTES,
                                             combined.length);
            return new GcmResult(useIv, tag, ct);
        } catch (GeneralSecurityException e) {
            throw new RuntimeException("per-AU AES-256-GCM encrypt failed", e);
        }
    }

    /** AES-256-GCM decrypt + authenticate. Throws on tag / AAD mismatch. */
    public static byte[] decryptWithAad(byte[] iv, byte[] tag,
                                          byte[] ciphertext, byte[] key,
                                          byte[] aad) {
        requireKey(key);
        if (iv.length != IV_BYTES) {
            throw new IllegalArgumentException(
                "IV must be " + IV_BYTES + " bytes, got " + iv.length);
        }
        if (tag.length != TAG_BYTES) {
            throw new IllegalArgumentException(
                "tag must be " + TAG_BYTES + " bytes, got " + tag.length);
        }
        try {
            byte[] combined = new byte[ciphertext.length + TAG_BYTES];
            System.arraycopy(ciphertext, 0, combined, 0, ciphertext.length);
            System.arraycopy(tag, 0, combined, ciphertext.length, TAG_BYTES);
            Cipher cipher = Cipher.getInstance(GCM_ALGO);
            cipher.init(Cipher.DECRYPT_MODE,
                        new SecretKeySpec(key, "AES"),
                        new GCMParameterSpec(TAG_BITS, iv));
            if (aad != null) cipher.updateAAD(aad);
            return cipher.doFinal(combined);
        } catch (GeneralSecurityException e) {
            throw new RuntimeException("per-AU AES-256-GCM decrypt failed", e);
        }
    }

    /** Generate a 12-byte cryptographically-random IV. */
    public static byte[] randomIv() {
        byte[] iv = new byte[IV_BYTES];
        RNG.nextBytes(iv);
        return iv;
    }

    private static void requireKey(byte[] key) {
        if (key.length != KEY_BYTES) {
            throw new IllegalArgumentException(
                "AES-256-GCM key must be " + KEY_BYTES + " bytes, got "
                    + key.length);
        }
    }

    // ---------------------------------------------------- Segment types

    /** One encrypted row of a {@code <channel>_segments} compound
     *  dataset. */
    public record ChannelSegment(long offset, int length,
                                    byte[] iv, byte[] tag,
                                    byte[] ciphertext) {}

    /** One encrypted row of {@code spectrum_index/au_header_segments}. */
    public record HeaderSegment(byte[] iv, byte[] tag, byte[] ciphertext) {}

    /** Plaintext form of the 36-byte AU semantic header. */
    public record AUHeaderPlaintext(int acquisitionMode, int msLevel,
                                      int polarity, double retentionTime,
                                      double precursorMz, int precursorCharge,
                                      double ionMobility,
                                      double basePeakIntensity) {}

    // ------------------------------------------------ Channel segments

    /** Slice flat float64 plaintext into per-spectrum rows and
     *  encrypt each with a fresh IV. */
    public static List<ChannelSegment> encryptChannelToSegments(
            byte[] plaintextFloat64Le, long[] offsets, int[] lengths,
            int datasetId, String channelName, byte[] key) {
        if (offsets.length != lengths.length) {
            throw new IllegalArgumentException(
                "offsets / lengths length mismatch");
        }
        List<ChannelSegment> out = new ArrayList<>(offsets.length);
        for (int auSeq = 0; auSeq < offsets.length; auSeq++) {
            long off = offsets[auSeq];
            int len = lengths[auSeq];
            int byteOff = Math.toIntExact(off * 8L);
            int byteLen = len * 8;
            byte[] chunk = Arrays.copyOfRange(plaintextFloat64Le,
                                                byteOff, byteOff + byteLen);
            byte[] aad = aadForChannel(datasetId, auSeq, channelName);
            GcmResult r = encryptWithAad(chunk, key, aad, null);
            out.add(new ChannelSegment(off, len, r.iv(), r.tag(),
                                         r.ciphertext()));
        }
        return out;
    }

    /** Decrypt every row in order and concatenate plaintext float64
     *  bytes. */
    public static byte[] decryptChannelFromSegments(
            List<ChannelSegment> segments, int datasetId,
            String channelName, byte[] key) {
        int total = 0;
        for (ChannelSegment s : segments) total += s.length() * 8;
        byte[] out = new byte[total];
        int cursor = 0;
        for (int auSeq = 0; auSeq < segments.size(); auSeq++) {
            ChannelSegment s = segments.get(auSeq);
            byte[] aad = aadForChannel(datasetId, auSeq, channelName);
            byte[] plain = decryptWithAad(s.iv(), s.tag(), s.ciphertext(),
                                            key, aad);
            int expected = s.length() * 8;
            if (plain.length != expected) {
                throw new IllegalStateException(
                    "channel " + channelName + " segment " + auSeq
                    + ": decrypted " + plain.length + " bytes, expected "
                    + expected);
            }
            System.arraycopy(plain, 0, out, cursor, plain.length);
            cursor += plain.length;
        }
        return out;
    }

    // ----------------------------------------------- Header segments

    /** Pack a semantic header into the canonical 36-byte plaintext. */
    public static byte[] packAUHeaderPlaintext(AUHeaderPlaintext h) {
        byte[] out = new byte[HEADER_PLAINTEXT_BYTES];
        ByteBuffer bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN);
        bb.put((byte) (h.acquisitionMode() & 0xFF));
        bb.put((byte) (h.msLevel() & 0xFF));
        bb.put((byte) (h.polarity() & 0xFF));
        bb.putDouble(h.retentionTime());
        bb.putDouble(h.precursorMz());
        bb.put((byte) (h.precursorCharge() & 0xFF));
        bb.putDouble(h.ionMobility());
        bb.putDouble(h.basePeakIntensity());
        return out;
    }

    /** Inverse of {@link #packAUHeaderPlaintext}. */
    public static AUHeaderPlaintext unpackAUHeaderPlaintext(byte[] plain) {
        if (plain.length != HEADER_PLAINTEXT_BYTES) {
            throw new IllegalArgumentException(
                "AU header plaintext must be " + HEADER_PLAINTEXT_BYTES
                + " bytes, got " + plain.length);
        }
        ByteBuffer bb = ByteBuffer.wrap(plain).order(ByteOrder.LITTLE_ENDIAN);
        int acq = bb.get() & 0xFF;
        int ms = bb.get() & 0xFF;
        int pol = bb.get();              // signed i8 → i32
        double rt = bb.getDouble();
        double pmz = bb.getDouble();
        int pc = bb.get() & 0xFF;
        double ionMob = bb.getDouble();
        double bpi = bb.getDouble();
        return new AUHeaderPlaintext(acq, ms, pol, rt, pmz, pc, ionMob, bpi);
    }

    /** Encrypt one {@link AUHeaderPlaintext} per spectrum into
     *  {@link HeaderSegment}s. */
    public static List<HeaderSegment> encryptHeaderSegments(
            List<AUHeaderPlaintext> rows, int datasetId, byte[] key) {
        List<HeaderSegment> out = new ArrayList<>(rows.size());
        for (int auSeq = 0; auSeq < rows.size(); auSeq++) {
            byte[] plain = packAUHeaderPlaintext(rows.get(auSeq));
            byte[] aad = aadForHeader(datasetId, auSeq);
            GcmResult r = encryptWithAad(plain, key, aad, null);
            out.add(new HeaderSegment(r.iv(), r.tag(), r.ciphertext()));
        }
        return out;
    }

    /** Decrypt and unpack {@link HeaderSegment}s into
     *  {@link AUHeaderPlaintext}s. */
    public static List<AUHeaderPlaintext> decryptHeaderSegments(
            List<HeaderSegment> segments, int datasetId, byte[] key) {
        List<AUHeaderPlaintext> out = new ArrayList<>(segments.size());
        for (int auSeq = 0; auSeq < segments.size(); auSeq++) {
            HeaderSegment s = segments.get(auSeq);
            byte[] aad = aadForHeader(datasetId, auSeq);
            byte[] plain = decryptWithAad(s.iv(), s.tag(), s.ciphertext(),
                                            key, aad);
            out.add(unpackAUHeaderPlaintext(plain));
        }
        return out;
    }
}
