/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

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
    /**
     * Phase 2c-T bulk mode (transport-spec §4.10): verbatim
     * {@code mate_info/inline_v2} blob carriage. Emitted only when
     * the StreamHeader features list contains
     * {@code "bulk_mode_v2_blobs"}.
     */
    BLOB_V2_MATE_INFO   (0x09),
    /** Phase 2c-T bulk mode (transport-spec §4.11): verbatim
     * {@code sequences/refdiff_v2} blob carriage. */
    BLOB_V2_REF_DIFF    (0x0A),
    /** Phase 2c-T bulk mode (transport-spec §4.12): verbatim
     * {@code read_names/name_tok_v2} blob carriage. */
    BLOB_V2_NAME_TOK    (0x0B),
    END_OF_STREAM       (0xFF);

    /** Phase 2c-T feature flag in StreamHeader features list. */
    public static final String BULK_MODE_V2_BLOBS_FEATURE =
        "bulk_mode_v2_blobs";

    /** Phase 2c-T codec id constants (mirror enums.Compression). */
    public static final int CODEC_ID_MATE_INLINE_V2    = 13;
    public static final int CODEC_ID_REF_DIFF_V2       = 14;
    public static final int CODEC_ID_NAME_TOKENIZED_V2 = 15;

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
