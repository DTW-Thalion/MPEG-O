/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Forward-compat: v0.10 readers must tolerate unknown packet type
 * bytes by length-prefix-skipping the payload (transport-spec §6,
 * v0.11 task 0.3).
 */
class TransportReaderSkipUnknownTest {

    /** Write a packet header + payload with no checksum and an
     *  arbitrary (potentially unknown) wire type byte. */
    private static void writeRawPacket(ByteArrayOutputStream out,
                                         int typeByte,
                                         byte[] payload) {
        ByteBuffer buf = ByteBuffer.allocate(PacketHeader.HEADER_SIZE)
                .order(ByteOrder.LITTLE_ENDIAN);
        buf.put(PacketHeader.MAGIC);
        buf.put(PacketHeader.VERSION);
        buf.put((byte) (typeByte & 0xFF));
        buf.putShort((short) 0);        // flags
        buf.putShort((short) 0);        // dataset_id
        buf.putInt(0);                  // au_sequence
        buf.putInt(payload.length);     // payload_length
        buf.putLong(0L);                // timestamp_ns
        out.writeBytes(buf.array());
        out.writeBytes(payload);
    }

    @Test
    void unknown_packet_type_is_skipped_not_thrown() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        TransportWriter w = new TransportWriter(out);
        w.writeStreamHeader("1.2", "test", "",
            java.util.List.of("transport_v0_11"), 0);

        // Manually splice in a packet whose type byte (0x7E) is not
        // a known PacketType. The reader must consume the length-
        // prefixed payload and continue past it to EndOfStream.
        byte[] payload = "future-extension-data".getBytes();
        writeRawPacket(out, 0x7E, payload);

        w.writeEndOfStream();

        TransportReader r = new TransportReader(out.toByteArray());
        List<TransportReader.PacketRecord> records = r.recordsForTest();

        assertEquals(3, records.size(), "StreamHeader + unknown + EndOfStream");

        TransportReader.PacketRecord skipped = records.get(1);
        assertNull(skipped.header.packetType,
            "unknown wire byte must surface as null PacketType");
        assertEquals(0x7E, skipped.header.packetTypeByte(),
            "raw type byte must be preserved on the header");
        assertArrayEquals(payload, skipped.payload,
            "payload bytes were length-prefixed and copied verbatim");

        assertEquals(PacketType.STREAM_HEADER,
            records.get(0).header.packetType);
        assertEquals(PacketType.END_OF_STREAM,
            records.get(2).header.packetType);
    }
}
