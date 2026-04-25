/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.transport;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * One signal channel inside an {@link AccessUnit}. ``precision`` and
 * ``compression`` are the wire encoding enums matching
 * {@link com.dtwthalion.ttio.Enums.Precision} and
 * {@link com.dtwthalion.ttio.Enums.Compression}.
 */
public final class ChannelData {

    public final String name;
    public final int precision;
    public final int compression;
    public final int nElements;
    public final byte[] data;

    public ChannelData(String name, int precision, int compression,
                        int nElements, byte[] data) {
        this.name = name;
        this.precision = precision;
        this.compression = compression;
        this.nElements = nElements;
        this.data = data;
    }

    /** Append this channel's wire bytes to {@code sink}. */
    public void appendTo(ByteBuffer sink) {
        byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
        sink.putShort((short) (nameBytes.length & 0xFFFF));
        sink.put(nameBytes);
        sink.put((byte) (precision & 0xFF));
        sink.put((byte) (compression & 0xFF));
        sink.putInt(nElements);
        sink.putInt(data.length);
        sink.put(data);
    }

    /** Decode one channel starting at {@code buf.position()}. */
    public static ChannelData decode(ByteBuffer buf) {
        int nameLen = buf.getShort() & 0xFFFF;
        byte[] nameBytes = new byte[nameLen];
        buf.get(nameBytes);
        String name = new String(nameBytes, StandardCharsets.UTF_8);
        int precision = buf.get() & 0xFF;
        int compression = buf.get() & 0xFF;
        int nElements = buf.getInt();
        int dataLen = buf.getInt();
        byte[] data = new byte[dataLen];
        buf.get(data);
        return new ChannelData(name, precision, compression, nElements, data);
    }

    public int encodedSize() {
        int nameLen = name.getBytes(StandardCharsets.UTF_8).length;
        return 2 + nameLen + 1 + 1 + 4 + 4 + data.length;
    }
}
