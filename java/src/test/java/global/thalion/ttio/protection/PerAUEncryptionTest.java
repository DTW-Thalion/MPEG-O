/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v1.0 per-AU encryption primitives — Java parity with Python
 * {@code ttio.encryption_per_au} and Objective-C
 * {@code TTIOPerAUEncryption}.
 */
class PerAUEncryptionTest {

    private static byte[] testKey() {
        byte[] k = new byte[32];
        java.util.Arrays.fill(k, (byte) 0x77);
        return k;
    }

    // ── AAD byte-exact parity with Python / ObjC ───────────────────

    @Test
    void aadForChannelMatchesWireFormat() {
        byte[] a = PerAUEncryption.aadForChannel(0x1234, 0xA5A5A5A5L, "mz");
        // dataset_id LE (2) + au_sequence LE (4) + "mz" utf8 (2) = 8
        assertEquals(8, a.length);
        assertEquals((byte) 0x34, a[0]);
        assertEquals((byte) 0x12, a[1]);
        assertEquals((byte) 0xA5, a[2]);
        assertEquals((byte) 0xA5, a[3]);
        assertEquals((byte) 0xA5, a[4]);
        assertEquals((byte) 0xA5, a[5]);
        assertEquals((byte) 'm', a[6]);
        assertEquals((byte) 'z', a[7]);
    }

    @Test
    void aadForHeaderAppendsLiteralHeaderTag() {
        byte[] a = PerAUEncryption.aadForHeader(1, 0);
        assertArrayEquals(
            new byte[]{0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                       'h', 'e', 'a', 'd', 'e', 'r'},
            a);
    }

    @Test
    void aadForPixelAppendsLiteralPixelTag() {
        byte[] a = PerAUEncryption.aadForPixel(1, 0);
        assertArrayEquals(
            new byte[]{0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                       'p', 'i', 'x', 'e', 'l'},
            a);
    }

    // ── AES-GCM round trip ───────────────────────────────────────────

    @Test
    void encryptDecryptRoundTripsWithAad() {
        byte[] key = testKey();
        byte[] aad = PerAUEncryption.aadForChannel(42, 7, "intensity");
        byte[] pt = "hello per-AU world".getBytes();
        PerAUEncryption.GcmResult r = PerAUEncryption.encryptWithAad(pt, key, aad, null);
        assertEquals(12, r.iv().length);
        assertEquals(16, r.tag().length);
        byte[] back = PerAUEncryption.decryptWithAad(r.iv(), r.tag(), r.ciphertext(),
                                                        key, aad);
        assertArrayEquals(pt, back);
    }

    @Test
    void decryptFailsOnAadMismatch() {
        byte[] key = testKey();
        byte[] aadGood = PerAUEncryption.aadForChannel(42, 7, "intensity");
        byte[] aadBad  = PerAUEncryption.aadForChannel(42, 7, "mz");
        PerAUEncryption.GcmResult r = PerAUEncryption.encryptWithAad(
            new byte[]{1, 2, 3, 4}, key, aadGood, null);
        assertThrows(RuntimeException.class, () ->
            PerAUEncryption.decryptWithAad(r.iv(), r.tag(), r.ciphertext(),
                                              key, aadBad));
    }

    @Test
    void decryptFailsOnAuSequenceMismatch() {
        byte[] key = testKey();
        byte[] aadAu0 = PerAUEncryption.aadForChannel(1, 0, "mz");
        byte[] aadAu1 = PerAUEncryption.aadForChannel(1, 1, "mz");
        PerAUEncryption.GcmResult r = PerAUEncryption.encryptWithAad(
            new byte[]{9, 8, 7}, key, aadAu0, null);
        assertThrows(RuntimeException.class, () ->
            PerAUEncryption.decryptWithAad(r.iv(), r.tag(), r.ciphertext(),
                                              key, aadAu1));
    }

    // ── Channel segment round trip ────────────────────────────────

    @Test
    void channelSegmentsRoundTripBitForBit() {
        int nSpectra = 4, perSpectrum = 5;
        int total = nSpectra * perSpectrum;
        ByteBuffer bb = ByteBuffer.allocate(total * 8).order(ByteOrder.LITTLE_ENDIAN);
        double[] src = new double[total];
        for (int i = 0; i < total; i++) {
            src[i] = 1000.0 + i * 0.25;
            bb.putDouble(src[i]);
        }
        long[] offsets = new long[nSpectra];
        int[] lengths = new int[nSpectra];
        for (int i = 0; i < nSpectra; i++) {
            offsets[i] = (long) i * perSpectrum;
            lengths[i] = perSpectrum;
        }

        List<PerAUEncryption.ChannelSegment> segs =
            PerAUEncryption.encryptChannelToSegments(bb.array(), offsets, lengths,
                                                        1, "mz", testKey());
        assertEquals(nSpectra, segs.size());
        for (PerAUEncryption.ChannelSegment s : segs) {
            assertEquals(12, s.iv().length);
            assertEquals(16, s.tag().length);
            assertEquals(perSpectrum * 8, s.ciphertext().length);
        }
        byte[] back = PerAUEncryption.decryptChannelFromSegments(segs, 1, "mz",
                                                                    testKey());
        assertArrayEquals(bb.array(), back);
    }

    // ── Header plaintext pack / unpack ────────────────────────────

    @Test
    void headerPlaintextIs36Bytes() {
        PerAUEncryption.AUHeaderPlaintext h = new PerAUEncryption.AUHeaderPlaintext(
            1, 2, -1, 12.5, 500.25, 2, 0.75, 99.9);
        byte[] packed = PerAUEncryption.packAUHeaderPlaintext(h);
        assertEquals(36, packed.length);
        PerAUEncryption.AUHeaderPlaintext back =
            PerAUEncryption.unpackAUHeaderPlaintext(packed);
        assertEquals(h.acquisitionMode(), back.acquisitionMode());
        assertEquals(h.msLevel(), back.msLevel());
        assertEquals(h.polarity(), back.polarity());
        assertEquals(h.retentionTime(), back.retentionTime(), 0.0);
        assertEquals(h.precursorMz(), back.precursorMz(), 0.0);
        assertEquals(h.precursorCharge(), back.precursorCharge());
        assertEquals(h.ionMobility(), back.ionMobility(), 0.0);
        assertEquals(h.basePeakIntensity(), back.basePeakIntensity(), 0.0);
    }

    @Test
    void unpackHeaderRejectsWrongLength() {
        assertThrows(IllegalArgumentException.class, () ->
            PerAUEncryption.unpackAUHeaderPlaintext(new byte[35]));
        assertThrows(IllegalArgumentException.class, () ->
            PerAUEncryption.unpackAUHeaderPlaintext(new byte[37]));
    }

    // ── Header segment round trip ─────────────────────────────────

    @Test
    void headerSegmentsRoundTrip() {
        List<PerAUEncryption.AUHeaderPlaintext> rows = new ArrayList<>();
        rows.add(new PerAUEncryption.AUHeaderPlaintext(1, 1, 1, 1.0, 0.0, 0, 0.0, 10.0));
        rows.add(new PerAUEncryption.AUHeaderPlaintext(1, 2, 1, 2.0, 500.0, 2, 0.0, 20.0));
        rows.add(new PerAUEncryption.AUHeaderPlaintext(1, 1, 1, 3.0, 0.0, 0, 0.0, 30.0));

        List<PerAUEncryption.HeaderSegment> segs =
            PerAUEncryption.encryptHeaderSegments(rows, 7, testKey());
        assertEquals(3, segs.size());
        for (PerAUEncryption.HeaderSegment s : segs) {
            assertEquals(12, s.iv().length);
            assertEquals(16, s.tag().length);
            assertEquals(36, s.ciphertext().length);
        }
        List<PerAUEncryption.AUHeaderPlaintext> back =
            PerAUEncryption.decryptHeaderSegments(segs, 7, testKey());
        assertEquals(rows, back);
    }

    // ── Key validation ────────────────────────────────────────────

    @Test
    void rejectsWrongKeySize() {
        assertThrows(IllegalArgumentException.class, () ->
            PerAUEncryption.encryptWithAad(new byte[1], new byte[16],
                                              new byte[0], null));
    }

    // ── Cross-language conformance with Python ───────────────────

    /** Vector generated by
     *  {@code python/src/ttio/encryption_per_au.py} with
     *  key = 0x77×32, iv = 0x42×12, datasetId = 0x1234, auSeq = 7,
     *  channel = "mz", plaintext = "cross-lang parity test". */
    @Test
    void decryptsPythonReferenceVector() {
        byte[] key = testKey();
        byte[] iv = new byte[12];
        java.util.Arrays.fill(iv, (byte) 0x42);
        byte[] aad = PerAUEncryption.aadForChannel(0x1234, 7, "mz");
        byte[] tag = hex("30d5d1c922d00d28a35a1ee7633596ab");
        byte[] ct  = hex("6a549b915474a4b97a2f9d743e57ce6134f0dcf5017a");
        byte[] pt  = PerAUEncryption.decryptWithAad(iv, tag, ct, key, aad);
        assertArrayEquals("cross-lang parity test".getBytes(), pt);
    }

    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }
}
