/*
 * TTI-O Java Implementation — v0.10 M71.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.transport;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * ProtectionMetadata packet payload (v0.10 M71) per
 * {@code docs/transport-spec.md} §4.4.
 *
 * <p>Wire order: {@code cipher_suite} / {@code kek_algorithm} /
 * {@code wrapped_dek} / {@code signature_algorithm} /
 * {@code public_key}. Each string has a uint16 length prefix, each
 * byte-blob has a uint32 length prefix.</p>
 *
 * <p>Full codec emission of encrypted AUs is a v1.0 integration item;
 * this class ships the wire-stable packet so tooling can emit and
 * parse the protocol today. Cross-language equivalents: Python
 * {@code tests/test_transport_selective_access.py} helpers, ObjC
 * {@code TTIOProtectionMetadata}.</p>
 */
public final class ProtectionMetadata {

    public final String cipherSuite;
    public final String kekAlgorithm;
    public final byte[] wrappedDek;
    public final String signatureAlgorithm;
    public final byte[] publicKey;

    public ProtectionMetadata(String cipherSuite, String kekAlgorithm,
                                byte[] wrappedDek, String signatureAlgorithm,
                                byte[] publicKey) {
        this.cipherSuite = cipherSuite;
        this.kekAlgorithm = kekAlgorithm;
        this.wrappedDek = wrappedDek;
        this.signatureAlgorithm = signatureAlgorithm;
        this.publicKey = publicKey;
    }

    public byte[] encode() {
        byte[] cs = cipherSuite.getBytes(StandardCharsets.UTF_8);
        byte[] kek = kekAlgorithm.getBytes(StandardCharsets.UTF_8);
        byte[] sig = signatureAlgorithm.getBytes(StandardCharsets.UTF_8);
        int size = 2 + cs.length
                 + 2 + kek.length
                 + 4 + wrappedDek.length
                 + 2 + sig.length
                 + 4 + publicKey.length;
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) (cs.length & 0xFFFF)); buf.put(cs);
        buf.putShort((short) (kek.length & 0xFFFF)); buf.put(kek);
        buf.putInt(wrappedDek.length); buf.put(wrappedDek);
        buf.putShort((short) (sig.length & 0xFFFF)); buf.put(sig);
        buf.putInt(publicKey.length); buf.put(publicKey);
        return buf.array();
    }

    public static ProtectionMetadata decode(byte[] bytes) {
        ByteBuffer buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        String cs = readLEString(buf, 2);
        String kek = readLEString(buf, 2);
        int wrappedLen = buf.getInt();
        byte[] wrapped = new byte[wrappedLen]; buf.get(wrapped);
        String sig = readLEString(buf, 2);
        int pkLen = buf.getInt();
        byte[] pk = new byte[pkLen]; buf.get(pk);
        return new ProtectionMetadata(cs, kek, wrapped, sig, pk);
    }

    private static String readLEString(ByteBuffer buf, int widthBytes) {
        int len;
        if (widthBytes == 2) len = buf.getShort() & 0xFFFF;
        else                  len = buf.getInt();
        byte[] b = new byte[len]; buf.get(b);
        return new String(b, StandardCharsets.UTF_8);
    }
}
