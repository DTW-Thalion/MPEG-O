/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.genomics.ReferenceImport;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage 1 / Task 1.2 (transport-spec v0.11): exercise
 * {@link TransportWriter#writeReferenceGroup(ReferenceImport)} and
 * verify the emitted packet sequence matches §4.13–§4.15 of the
 * transport spec.
 */
class TransportWriterReferenceTest {

    @Test
    void writeReferenceGroup_emits_header_chromosomes_eof_in_order() throws Exception {
        ReferenceImport ref = new ReferenceImport(
            "fixture-test-ref-v1",
            List.of("chr1", "chr2"),
            List.of("ACGT".getBytes(StandardCharsets.UTF_8),
                    "TTTTCC".getBytes(StandardCharsets.UTF_8)));

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter w = new TransportWriter(out)) {
            w.writeStreamHeader("1.2", "ref-test", "isa", List.of(), 0);
            w.writeReferenceGroup(ref);
            w.writeEndOfStream();
        }

        TransportReader r = new TransportReader(out.toByteArray());
        var records = r.recordsForTest();
        // Expected sequence: StreamHeader, RefGroupHeader, 2× RefChromosome, EOR, EOS.
        assertEquals(6, records.size(),
            "expected 6 packets, got " + records.size());
        assertEquals(PacketType.STREAM_HEADER,
            records.get(0).header.packetType);
        assertEquals(PacketType.REFERENCE_GROUP_HEADER,
            records.get(1).header.packetType);
        assertEquals(PacketType.REFERENCE_CHROMOSOME,
            records.get(2).header.packetType);
        assertEquals(PacketType.REFERENCE_CHROMOSOME,
            records.get(3).header.packetType);
        assertEquals(PacketType.END_OF_REFERENCE_GROUP,
            records.get(4).header.packetType);
        assertEquals(PacketType.END_OF_STREAM,
            records.get(5).header.packetType);

        // Header payload fields (LE per transport-spec §1.7).
        ByteBuffer hbuf = ByteBuffer.wrap(records.get(1).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int uriLen = hbuf.getShort() & 0xFFFF;
        byte[] uriB = new byte[uriLen];
        hbuf.get(uriB);
        assertEquals("fixture-test-ref-v1",
            new String(uriB, StandardCharsets.UTF_8));
        int chromCount = hbuf.getInt();
        assertEquals(2, chromCount);
        long totalBases = hbuf.getLong();
        assertEquals(10L, totalBases);   // 4 + 6
        byte[] md5Hex = new byte[32];
        hbuf.get(md5Hex);
        String md5 = new String(md5Hex, StandardCharsets.US_ASCII);
        assertEquals(ref.md5Hex(), md5,
            "md5 hex must match ReferenceImport.md5Hex()");

        // chr1 payload: uncompressed (length 4 < 4096).
        ByteBuffer c1 = ByteBuffer.wrap(records.get(2).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int n1 = c1.getShort() & 0xFFFF;
        byte[] name1 = new byte[n1];
        c1.get(name1);
        assertEquals("chr1", new String(name1, StandardCharsets.UTF_8));
        assertEquals(4L, c1.getLong());
        assertEquals(0, c1.get() & 0xFF, "encoding=0 raw for short chromosome");
        int pl1 = c1.getInt();
        assertEquals(4, pl1);
        byte[] data1 = new byte[pl1];
        c1.get(data1);
        assertArrayEquals("ACGT".getBytes(StandardCharsets.UTF_8), data1);
        // au_sequence carries the chromosome index.
        assertEquals(0L, records.get(2).header.auSequence);

        // chr2 payload: also short (6 < 4096) -> uncompressed.
        ByteBuffer c2 = ByteBuffer.wrap(records.get(3).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int n2 = c2.getShort() & 0xFFFF;
        byte[] name2 = new byte[n2];
        c2.get(name2);
        assertEquals("chr2", new String(name2, StandardCharsets.UTF_8));
        assertEquals(6L, c2.getLong());
        assertEquals(0, c2.get() & 0xFF);
        int pl2 = c2.getInt();
        assertEquals(6, pl2);
        byte[] data2 = new byte[pl2];
        c2.get(data2);
        assertArrayEquals("TTTTCC".getBytes(StandardCharsets.UTF_8), data2);
        assertEquals(1L, records.get(3).header.auSequence);

        // EOR payload carries the count for integrity.
        ByteBuffer ebuf = ByteBuffer.wrap(records.get(4).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        assertEquals(2, ebuf.getInt());
    }

    @Test
    void writeReferenceGroup_zlib_path_above_threshold() throws Exception {
        // Build an 8 KB chromosome to force the encoding=1 zlib path.
        byte[] big = new byte[8192];
        java.util.Arrays.fill(big, (byte) 'A');
        // Add some variability so zlib actually compresses non-trivially.
        for (int i = 0; i < big.length; i++) {
            big[i] = (byte) ("ACGT".charAt(i & 3));
        }
        ReferenceImport ref = new ReferenceImport(
            "ref-large",
            List.of("chrL"),
            List.of(big));

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter w = new TransportWriter(out)) {
            w.writeStreamHeader("1.2", "ref-test", "isa", List.of(), 0);
            w.writeReferenceGroup(ref);
            w.writeEndOfStream();
        }

        TransportReader r = new TransportReader(out.toByteArray());
        var records = r.recordsForTest();
        assertEquals(5, records.size());
        assertEquals(PacketType.REFERENCE_CHROMOSOME,
            records.get(2).header.packetType);

        ByteBuffer c1 = ByteBuffer.wrap(records.get(2).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int n1 = c1.getShort() & 0xFFFF;
        c1.get(new byte[n1]);
        assertEquals(8192L, c1.getLong());
        assertEquals(1, c1.get() & 0xFF, "encoding=1 zlib for >= 4096 bytes");
        int pl1 = c1.getInt();
        assertTrue(pl1 < 8192, "zlib should compress repeating ACGT bytes");
        byte[] data1 = new byte[pl1];
        c1.get(data1);

        // Decompress and verify round-trip.
        java.util.zip.Inflater inf = new java.util.zip.Inflater();
        inf.setInput(data1);
        byte[] decoded = new byte[8192];
        int produced = inf.inflate(decoded);
        inf.end();
        assertEquals(8192, produced);
        assertArrayEquals(big, decoded);
    }
}
