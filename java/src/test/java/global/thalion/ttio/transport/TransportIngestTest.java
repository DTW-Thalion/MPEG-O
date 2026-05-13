/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests for {@link TransportIngest}.
 *
 * <p>Cross-language parity with {@code objc/Tests/TestTransportIngest.m}
 * and {@code python/tests/test_transport_ingest.py}. The 6 scenarios
 * mirror the ObjC tests packet-for-packet so a fix to one ingest
 * implementation that breaks parity will fail here too.</p>
 *
 * <p>Streams are crafted by hand via {@link PacketHeader#encode()} so
 * the test stays scoped to ingest streaming behaviour, not the full
 * dataset/writer pipeline.</p>
 */
class TransportIngestTest {

    // ── Crafting helpers ──────────────────────────────────────────

    /** Build one packet (header + payload + optional CRC). */
    private static byte[] craftPacket(PacketType type, int flags,
                                       int datasetId, long auSequence,
                                       byte[] payload) {
        PacketHeader h = new PacketHeader(type, flags, datasetId,
                auSequence, payload.length, 0L);
        byte[] hdr = h.encode();
        boolean hasCrc = (flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0;
        int total = hdr.length + payload.length + (hasCrc ? 4 : 0);
        byte[] out = new byte[total];
        System.arraycopy(hdr, 0, out, 0, hdr.length);
        System.arraycopy(payload, 0, out, hdr.length, payload.length);
        if (hasCrc) {
            int crc = Crc32c.compute(payload);
            ByteBuffer.wrap(out, hdr.length + payload.length, 4)
                .order(ByteOrder.LITTLE_ENDIAN).putInt(crc);
        }
        return out;
    }

    /** Minimal valid stream: StreamHeader + 3 AU + EndOfStream, all
     *  with HAS_CHECKSUM so the ingest exercises that path. */
    private static byte[] craftSampleStream() throws IOException {
        int flags = PacketHeader.FLAG_HAS_CHECKSUM;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(craftPacket(PacketType.STREAM_HEADER, flags, 0, 0,
                              "v0".getBytes(StandardCharsets.UTF_8)));
        for (int i = 1; i <= 3; i++) {
            byte[] payload = ("au-" + i + "-payload").getBytes(StandardCharsets.UTF_8);
            out.write(craftPacket(PacketType.ACCESS_UNIT, flags, 1, i, payload));
        }
        out.write(craftPacket(PacketType.END_OF_STREAM, flags, 0, 0, new byte[0]));
        return out.toByteArray();
    }

    // ── Recorder ─────────────────────────────────────────────────

    private static final class Recorder implements TransportIngest.Listener {
        final List<TransportIngest.PacketRecord> packets = new ArrayList<>();
        boolean endOfStreamFired = false;
        TransportIngest.IngestException failure = null;

        @Override public void onPacket(TransportIngest.PacketRecord rec) {
            packets.add(rec);
        }
        @Override public void onEndOfStream() {
            endOfStreamFired = true;
        }
        @Override public void onError(TransportIngest.IngestException e) {
            failure = e;
        }
    }

    // ── Tests ────────────────────────────────────────────────────

    @Test
    void wholeStreamFeed() throws IOException {
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        ingest.feed(craftSampleStream());

        assertEquals(5, rec.packets.size(), "StreamHeader + 3 AU + EndOfStream");
        assertTrue(rec.endOfStreamFired);
        assertTrue(ingest.isFinished());
        assertEquals(5L, ingest.packetCount());
        assertNull(rec.failure);
    }

    @Test
    void byteByByteFeed() throws IOException {
        byte[] stream = craftSampleStream();
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        for (int i = 0; i < stream.length; i++) {
            ingest.feed(stream, i, 1);
        }

        assertEquals(5, rec.packets.size());
        assertTrue(rec.endOfStreamFired);
        assertEquals(5L, ingest.packetCount());
        assertNull(rec.failure);
    }

    @Test
    void chunkedFeedSevenBytes() throws IOException {
        // 7-byte chunks straddle most packet boundaries — exercises
        // the rolling-buffer drain more thoroughly than byte-by-byte.
        byte[] stream = craftSampleStream();
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        int chunk = 7;
        for (int offset = 0; offset < stream.length; offset += chunk) {
            int len = Math.min(chunk, stream.length - offset);
            ingest.feed(stream, offset, len);
        }

        assertEquals(5, rec.packets.size());
        assertTrue(rec.endOfStreamFired);
    }

    @Test
    void badMagicFails() {
        // 24 bytes that look like a header but with bogus magic.
        byte[] garbage = new byte[24];
        garbage[0] = (byte) 'X';
        garbage[1] = (byte) 'X';
        garbage[2] = 0x01;

        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        assertThrows(TransportIngest.IngestException.class,
                     () -> ingest.feed(garbage));
        assertNotNull(rec.failure, "onError fired on bad magic");
        assertTrue(ingest.isFinished(), "ingest moves to finished/failed");
    }

    @Test
    void truncatedFinishFails() {
        // Feed only the StreamHeader's 24 header bytes, advertising a
        // 16-byte payload that never arrives; then call finish.
        PacketHeader h = new PacketHeader(PacketType.STREAM_HEADER, 0,
                0, 0L, 16L, 0L);
        byte[] partial = h.encode();

        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        ingest.feed(partial);
        assertEquals(0L, ingest.packetCount(),
                "no packets emitted yet (payload incomplete)");
        assertEquals(24, ingest.bufferedBytes(),
                "24 bytes buffered awaiting the missing payload");

        TransportIngest.IngestException err = assertThrows(
            TransportIngest.IngestException.class, ingest::finish);
        assertTrue(err.getMessage().contains("partial packet"));
        assertNotNull(rec.failure);
    }

    @Test
    void truncatedFinishWithEmptyBufferAlsoFails() {
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        TransportIngest.IngestException err = assertThrows(
            TransportIngest.IngestException.class, ingest::finish);
        assertTrue(err.getMessage().contains("without EndOfStream"));
        assertNotNull(rec.failure);
    }

    @Test
    void missingStreamHeaderFails() {
        byte[] au = craftPacket(PacketType.ACCESS_UNIT,
                                PacketHeader.FLAG_HAS_CHECKSUM,
                                1, 1,
                                "orphan".getBytes(StandardCharsets.UTF_8));

        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        TransportIngest.IngestException err = assertThrows(
            TransportIngest.IngestException.class, () -> ingest.feed(au));
        assertTrue(err.getMessage().contains("StreamHeader"));
        assertNotNull(rec.failure);
    }

    @Test
    void feedAfterFinishedThrows() throws IOException {
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        ingest.feed(craftSampleStream());
        assertTrue(ingest.isFinished());
        TransportIngest.IngestException err = assertThrows(
            TransportIngest.IngestException.class,
            () -> ingest.feed("more".getBytes(StandardCharsets.UTF_8)));
        assertTrue(err.getMessage().contains("finished"));
    }

    @Test
    void crcMismatchFails() throws IOException {
        // Flip a payload byte so the trailing CRC no longer matches.
        byte[] stream = craftSampleStream();
        // First packet (StreamHeader) carries HAS_CHECKSUM; its 2-byte
        // payload starts at byte 24. Corrupt it (not the CRC).
        stream[24] ^= (byte) 0xFF;
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        TransportIngest.IngestException err = assertThrows(
            TransportIngest.IngestException.class, () -> ingest.feed(stream));
        assertTrue(err.getMessage().contains("CRC-32C"));
        assertNotNull(rec.failure);
    }

    @Test
    void auSequenceRegressionFails() throws IOException {
        int flags = PacketHeader.FLAG_HAS_CHECKSUM;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(craftPacket(PacketType.STREAM_HEADER, flags, 0, 0,
                              "v0".getBytes(StandardCharsets.UTF_8)));
        out.write(craftPacket(PacketType.ACCESS_UNIT, flags, 1, 5,
                              "a".getBytes(StandardCharsets.UTF_8)));
        out.write(craftPacket(PacketType.ACCESS_UNIT, flags, 1, 3,
                              "b".getBytes(StandardCharsets.UTF_8)));

        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        TransportIngest.IngestException err = assertThrows(
            TransportIngest.IngestException.class,
            () -> ingest.feed(out.toByteArray()));
        assertTrue(err.getMessage().contains("regressed"));
        assertNotNull(rec.failure);
    }

    /**
     * The first AccessUnit may carry {@code auSequence == 0} — that is
     * what {@link TransportWriter#writeDataset} emits. The earlier
     * ingest gated its monotonicity check on {@code packetCount > 0},
     * which collided with the default {@code lastAuSequence == 0} and
     * incorrectly rejected the writer's output. Now we track first-AU-
     * seen explicitly.
     */
    @Test
    void firstAuAtSequenceZeroIsAccepted() throws IOException {
        int flags = PacketHeader.FLAG_HAS_CHECKSUM;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(craftPacket(PacketType.STREAM_HEADER, flags, 0, 0,
                              "v0".getBytes(StandardCharsets.UTF_8)));
        out.write(craftPacket(PacketType.ACCESS_UNIT, flags, 1, 0,
                              "a".getBytes(StandardCharsets.UTF_8)));
        out.write(craftPacket(PacketType.ACCESS_UNIT, flags, 1, 1,
                              "b".getBytes(StandardCharsets.UTF_8)));

        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        ingest.feed(out.toByteArray());
        assertNull(rec.failure);
        long auCount = rec.packets.stream()
            .filter(p -> p.header.packetType == PacketType.ACCESS_UNIT)
            .count();
        assertEquals(2L, auCount);
    }

    @Test
    void emptyFeedIsNoOp() {
        Recorder rec = new Recorder();
        TransportIngest ingest = new TransportIngest(rec);
        ingest.feed(new byte[0]);
        ingest.feed(null);
        assertFalse(ingest.isFinished());
        assertEquals(0, ingest.bufferedBytes());
        assertEquals(0L, ingest.packetCount());
    }
}
