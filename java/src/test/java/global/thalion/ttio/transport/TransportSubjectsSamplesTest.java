/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Sample;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Subject;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage 6 / Task 6.2 (transport-spec §4.22): exercise the
 * {@code SUBJECT_METADATA} (0x19) and {@code SAMPLE_METADATA} (0x1A)
 * packets on {@link TransportWriter} + {@link TransportReader}.
 *
 * <p>Wire layout per §4.22 (identical shape for both packet types,
 * dispatch by type byte):</p>
 * <pre>
 * arrow_ipc_length:    uint32
 * arrow_ipc:           bytes[arrow_ipc_length]   # self-describing Arrow IPC stream
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN (spec §1.7).</p>
 */
class TransportSubjectsSamplesTest {

    @Test
    void subject_metadata_round_trips_through_writer_and_reader(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildSubjectsOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // materializeTo returns an open handle; close via try-with.
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            assertEquals(a.subjects().size(), b.subjects().size(),
                "subject row count must round-trip");
            for (int i = 0; i < a.subjects().size(); i++) {
                Subject sa = a.subjects().get(i);
                Subject sb = b.subjects().get(i);
                assertEquals(sa.externalId(), sb.externalId());
                assertEquals(sa.project(),    sb.project());
                assertEquals(sa.sex(),        sb.sex());
                assertEquals(sa.birthYear(),  sb.birthYear());
                assertEquals(sa.attributes(), sb.attributes());
            }
            // Cross-cutting: subjects-only fixture must carry NO samples
            // both before and after the round-trip.
            assertTrue(a.samples().isEmpty());
            assertTrue(b.samples().isEmpty());
        }
    }

    @Test
    void sample_metadata_round_trips_through_writer_and_reader(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildSamplesOnly(tmp.resolve("src.tio"));
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
            assertEquals(a.samples().size(), b.samples().size(),
                "sample row count must round-trip");
            for (int i = 0; i < a.samples().size(); i++) {
                Sample sa = a.samples().get(i);
                Sample sb = b.samples().get(i);
                assertEquals(sa.sampleId(),          sb.sampleId());
                assertEquals(sa.subjectExternalId(), sb.subjectExternalId());
                assertEquals(sa.sampleKind(),        sb.sampleKind());
                assertEquals(sa.collectedAt(),       sb.collectedAt());
                assertEquals(sa.attributes(),        sb.attributes());
            }
            // Cross-cutting: samples-only fixture must carry NO subjects
            // both before and after the round-trip.
            assertTrue(a.subjects().isEmpty());
            assertTrue(b.subjects().isEmpty());
        }
    }

    /** Spec §5.4 step 5 says "zero or more" subject/sample tables; an
     *  empty list must NOT emit a 0x19 or 0x1A packet on the wire. The
     *  reference-only fixture stands in for "no subjects, no samples". */
    @Test
    void empty_lists_emit_no_subject_or_sample_packets(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildReferenceOnly(tmp.resolve("src.tio"));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }
        TransportReader r = new TransportReader(out.toByteArray());
        var packets = r.recordsForTest();
        for (var rec : packets) {
            assertNotEquals(PacketType.SUBJECT_METADATA,
                rec.header.packetType,
                "reference-only fixture must not emit SUBJECT_METADATA");
            assertNotEquals(PacketType.SAMPLE_METADATA,
                rec.header.packetType,
                "reference-only fixture must not emit SAMPLE_METADATA");
        }
    }

    /** Sanity: with both subjects and samples populated, the writer
     *  emits exactly one 0x19 followed by exactly one 0x1A (per
     *  §5.4 step 5, SUBJECT_METADATA precedes SAMPLE_METADATA). */
    @Test
    void both_tables_emit_in_spec_order(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildSubjectsAndSamples(tmp.resolve("both.tio"));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }
        TransportReader r = new TransportReader(out.toByteArray());
        var packets = r.recordsForTest();
        int subjIdx = -1;
        int sampIdx = -1;
        for (int i = 0; i < packets.size(); i++) {
            PacketType t = packets.get(i).header.packetType;
            if (t == PacketType.SUBJECT_METADATA) {
                assertEquals(-1, subjIdx, "duplicate SUBJECT_METADATA");
                subjIdx = i;
            } else if (t == PacketType.SAMPLE_METADATA) {
                assertEquals(-1, sampIdx, "duplicate SAMPLE_METADATA");
                sampIdx = i;
            }
        }
        assertTrue(subjIdx > 0, "expected exactly one SUBJECT_METADATA packet");
        assertTrue(sampIdx > 0, "expected exactly one SAMPLE_METADATA packet");
        assertTrue(subjIdx < sampIdx,
            "per spec §5.4 step 5: SUBJECT_METADATA precedes SAMPLE_METADATA");
    }
}
