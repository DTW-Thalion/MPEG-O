/*
 * MPEG-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.transport;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * 24-byte packet header for the MPEG-O transport format. See
 * {@code docs/transport-spec.md} §3.1.
 *
 * <p>Little-endian wire encoding: 2-byte magic {@code "MO"}, uint8
 * version, uint8 packet type, uint16 flags, uint16 dataset id, uint32
 * AU sequence, uint32 payload length, uint64 timestamp.</p>
 *
 * <p>Cross-language equivalents: Python
 * {@code mpeg_o.transport.packets.PacketHeader}, Objective-C
 * {@code MPGOTransportPacketHeader}.</p>
 */
public final class PacketHeader {

    public static final byte[] MAGIC = {(byte) 'M', (byte) 'O'};
    public static final byte VERSION = 0x01;
    public static final int HEADER_SIZE = 24;

    public static final int FLAG_ENCRYPTED    = 0x0001;
    public static final int FLAG_COMPRESSED   = 0x0002;
    public static final int FLAG_HAS_CHECKSUM = 0x0004;

    public final PacketType packetType;
    public final int flags;
    public final int datasetId;
    public final long auSequence;
    public final long payloadLength;
    public final long timestampNs;

    public PacketHeader(PacketType packetType, int flags, int datasetId,
                         long auSequence, long payloadLength, long timestampNs) {
        this.packetType = packetType;
        this.flags = flags;
        this.datasetId = datasetId;
        this.auSequence = auSequence;
        this.payloadLength = payloadLength;
        this.timestampNs = timestampNs;
    }

    public byte[] encode() {
        ByteBuffer buf = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN);
        buf.put(MAGIC);
        buf.put(VERSION);
        buf.put((byte) (packetType.wire() & 0xFF));
        buf.putShort((short) (flags & 0xFFFF));
        buf.putShort((short) (datasetId & 0xFFFF));
        buf.putInt((int) (auSequence & 0xFFFFFFFFL));
        buf.putInt((int) (payloadLength & 0xFFFFFFFFL));
        buf.putLong(timestampNs);
        return buf.array();
    }

    public static PacketHeader decode(byte[] bytes) {
        if (bytes.length < HEADER_SIZE) {
            throw new IllegalArgumentException(
                    "header needs " + HEADER_SIZE + " bytes, got " + bytes.length);
        }
        ByteBuffer buf = ByteBuffer.wrap(bytes, 0, HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN);
        byte m0 = buf.get();
        byte m1 = buf.get();
        if (m0 != MAGIC[0] || m1 != MAGIC[1]) {
            throw new IllegalArgumentException("invalid packet magic");
        }
        byte version = buf.get();
        if (version != VERSION) {
            throw new IllegalArgumentException("unsupported transport version: " + (version & 0xFF));
        }
        int pt = buf.get() & 0xFF;
        int flags = buf.getShort() & 0xFFFF;
        int datasetId = buf.getShort() & 0xFFFF;
        long auSequence = buf.getInt() & 0xFFFFFFFFL;
        long payloadLength = buf.getInt() & 0xFFFFFFFFL;
        long timestampNs = buf.getLong();
        return new PacketHeader(PacketType.fromWire(pt), flags, datasetId,
                auSequence, payloadLength, timestampNs);
    }
}
