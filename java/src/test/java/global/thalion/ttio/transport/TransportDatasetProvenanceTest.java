/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 1.6 (transport-spec §4.21): exercise the
 * {@code DATASET_PROVENANCE} (0x18) packet on
 * {@link TransportWriter} + {@link TransportReader}. Wire layout
 * per §4.21:
 *
 * <pre>
 * record_count:        uint32
 * # repeated record_count times:
 * timestamp_unix:      int64
 * software_length:     uint16
 * software:            bytes[software_length]      # UTF-8
 * parameters_length:   uint16
 * parameters_json:     bytes[parameters_length]    # UTF-8 JSON
 * input_refs_length:   uint16
 * input_refs_csv:      bytes[input_refs_length]    # UTF-8 comma-joined
 * output_refs_length:  uint16
 * output_refs_csv:     bytes[output_refs_length]   # UTF-8 comma-joined
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN (spec §1.7).</p>
 */
class TransportDatasetProvenanceTest {

    /** Writer's low-level helper emits a single 0x18 packet whose
     *  payload matches §4.21 exactly. */
    @Test
    void writeDatasetProvenance_emits_single_packet_with_record_count() throws Exception {
        Map<String, String> params = new LinkedHashMap<>();
        params.put("threshold", "0.5");
        ProvenanceRecord r1 = new ProvenanceRecord(
            1700000000L, "TTI-O Java 1.0.0",
            params,
            List.of("file:///in.raw", "file:///in2.raw"),
            List.of("file:///out.tio"));
        ProvenanceRecord r2 = new ProvenanceRecord(
            1700000100L, "step 2",
            Map.of(),
            List.of(),
            List.of("file:///final.tio"));

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter w = new TransportWriter(out)) {
            w.writeStreamHeader("1.2", "prov-test", "isa", List.of(), 0);
            w.writeDatasetProvenance(List.of(r1, r2));
            w.writeEndOfStream();
        }

        TransportReader r = new TransportReader(out.toByteArray());
        var records = r.recordsForTest();
        assertEquals(3, records.size(),
            "expected StreamHeader + DatasetProvenance + EndOfStream");
        assertEquals(PacketType.DATASET_PROVENANCE,
            records.get(1).header.packetType);

        ByteBuffer bb = ByteBuffer.wrap(records.get(1).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int recordCount = bb.getInt();
        assertEquals(2, recordCount);

        // Record 0.
        long ts0 = bb.getLong();
        assertEquals(1700000000L, ts0);
        String software0 = readLEString(bb, 2);
        assertEquals("TTI-O Java 1.0.0", software0);
        String params0 = readLEString(bb, 2);
        assertTrue(params0.contains("threshold"),
            "parameters_json must carry the params map");
        assertTrue(params0.contains("0.5"));
        String inputs0 = readLEString(bb, 2);
        assertEquals("file:///in.raw,file:///in2.raw", inputs0,
            "input_refs_csv must be comma-joined URIs");
        String outputs0 = readLEString(bb, 2);
        assertEquals("file:///out.tio", outputs0);

        // Record 1 (empty params/inputs).
        long ts1 = bb.getLong();
        assertEquals(1700000100L, ts1);
        assertEquals("step 2", readLEString(bb, 2));
        // Empty parameters render as "{}" by ProvenanceRecord.parametersJson().
        assertEquals("{}", readLEString(bb, 2));
        // Empty refs render as "" (no entries to join).
        assertEquals("", readLEString(bb, 2));
        assertEquals("file:///final.tio", readLEString(bb, 2));
        assertFalse(bb.hasRemaining(),
            "payload must contain only the 2 records, no trailing bytes");
    }

    /** writeDataset on a .tio carrying provenance emits exactly one
     *  DATASET_PROVENANCE packet (in the v0.11 prelude, between any
     *  ENCRYPTION_ALGORITHM and the reference groups per §5.4) AND
     *  flips the v0.11 feature flag. */
    @Test
    void writeDataset_emits_dataset_provenance_when_present(@TempDir Path tmp)
            throws Exception {
        Path src = buildProvenanceOnly(tmp.resolve("prov.tio"));
        Path tis = tmp.resolve("prov.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            assertFalse(ds.provenanceRecords().isEmpty(),
                "fixture precondition: dataset must carry provenance");
            try (OutputStream out = Files.newOutputStream(tis);
                 TransportWriter w = new TransportWriter(out)) {
                w.writeDataset(ds);
            }
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        String shFeatures = new String(records.get(0).payload,
            StandardCharsets.UTF_8);
        assertTrue(shFeatures.contains("transport_v0_11"),
            "StreamHeader must carry transport_v0_11 feature flag");

        int provCount = 0;
        for (var rec : records) {
            if (rec.header.packetType == PacketType.DATASET_PROVENANCE) {
                provCount++;
            }
        }
        assertEquals(1, provCount,
            "writeDataset on provenance-bearing .tio must emit exactly "
            + "one DATASET_PROVENANCE packet");
    }

    /** writeDataset on a .tio with NO provenance emits NO 0x18 packet. */
    @Test
    void writeDataset_no_packet_when_provenance_empty(@TempDir Path tmp)
            throws Exception {
        Path src = tmp.resolve("plain.tio");
        try (SpectralDataset ignore = SpectralDataset.create(
                src.toString(), "plain", "",
                List.of(), List.of(), List.of(), List.of())) {
            // empty plaintext dataset, no provenance.
        }
        Path tis = tmp.resolve("plain.tis");
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            assertTrue(ds.provenanceRecords().isEmpty(),
                "fixture precondition: dataset must carry no provenance");
            w.writeDataset(ds);
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        for (var rec : r.recordsForTest()) {
            assertNotEquals(PacketType.DATASET_PROVENANCE,
                rec.header.packetType,
                "empty-provenance dataset must not emit DATASET_PROVENANCE");
        }
    }

    /** End-to-end round-trip: writer emits DATASET_PROVENANCE, reader
     *  materialises it, the resulting on-disk .tio carries the same
     *  provenance records (count + per-record fields). */
    @Test
    void dataset_provenance_round_trips_via_writeDataset_materializeTo(
            @TempDir Path tmp) throws Exception {
        Path src = buildProvenanceOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            List<ProvenanceRecord> provA = a.provenanceRecords();
            List<ProvenanceRecord> provB = b.provenanceRecords();
            assertEquals(provA.size(), provB.size(),
                "round-tripped provenance record count must match source");
            for (int i = 0; i < provA.size(); i++) {
                ProvenanceRecord recA = provA.get(i);
                ProvenanceRecord recB = provB.get(i);
                assertEquals(recA.timestampUnix(), recB.timestampUnix(),
                    "timestamp_unix mismatch at record " + i);
                assertEquals(recA.software(), recB.software(),
                    "software mismatch at record " + i);
                assertEquals(recA.inputRefs(), recB.inputRefs(),
                    "input_refs mismatch at record " + i);
                assertEquals(recA.outputRefs(), recB.outputRefs(),
                    "output_refs mismatch at record " + i);
                // parameters: compare via the canonical JSON form.
                assertEquals(recA.parametersJson(), recB.parametersJson(),
                    "parameters mismatch at record " + i);
            }
        }
    }

    // ---------------------------------------------------------- helpers

    private static String readLEString(ByteBuffer bb, int widthBytes) {
        int len;
        if (widthBytes == 2) len = bb.getShort() & 0xFFFF;
        else                  len = bb.getInt();
        byte[] b = new byte[len];
        bb.get(b);
        return new String(b, StandardCharsets.UTF_8);
    }

    /** Build a minimal .tio carrying 2 provenance records, no runs,
     *  no encryption. Mirrors the {@link FixtureBuilder} pattern
     *  locally to keep this test self-contained. */
    private static Path buildProvenanceOnly(Path target) throws Exception {
        Map<String, String> params = new LinkedHashMap<>();
        params.put("mode", "strict");
        params.put("threshold", "0.5");
        ProvenanceRecord r1 = new ProvenanceRecord(
            1700000000L, "TTI-O Java 1.0.0",
            params,
            List.of("file:///in.raw", "file:///in2.raw"),
            List.of("file:///out.tio"));
        ProvenanceRecord r2 = new ProvenanceRecord(
            1700000100L, "downstream step",
            Map.of(),
            List.of(),
            List.of("file:///final.tio"));
        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "provenance_only", "",
                List.of(), List.of(), List.of(), List.of(r1, r2))) {
            // The provenance records are persisted as the root
            // /study/provenance_json attribute by create(...).
        }
        return target;
    }
}
