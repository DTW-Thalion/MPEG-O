/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.transport;

/**
 * Transport packet types. See {@code docs/transport-spec.md} §3.2.
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.transport.packets.PacketType}, Objective-C
 * {@code TTIOTransportPacketType}.</p>
 */
public enum PacketType {
    STREAM_HEADER       (0x01),
    DATASET_HEADER      (0x02),
    ACCESS_UNIT         (0x03),
    PROTECTION_METADATA (0x04),
    ANNOTATION          (0x05),
    PROVENANCE          (0x06),
    CHROMATOGRAM        (0x07),
    END_OF_DATASET      (0x08),
    END_OF_STREAM       (0xFF);

    private final int wire;
    PacketType(int wire) { this.wire = wire; }

    /** Wire byte value for this packet type. */
    public int wire() { return wire; }

    public static PacketType fromWire(int v) {
        for (PacketType t : values()) if (t.wire == v) return t;
        throw new IllegalArgumentException("unknown packet type: 0x"
                + Integer.toHexString(v));
    }
}
