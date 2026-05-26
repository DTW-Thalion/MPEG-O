/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Identification;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 1.8 (transport-spec §4.19 / §4.20): exercise the
 * {@code IDENTIFICATIONS_TABLE} (0x16) and {@code QUANTIFICATIONS_TABLE}
 * (0x17) packets on {@link TransportWriter} + {@link TransportReader}.
 *
 * <p>Wire layout per §4.19 / §4.20:</p>
 * <pre>
 * arrow_ipc_length:    uint32
 * arrow_ipc:           bytes[arrow_ipc_length]   # self-describing Arrow IPC stream
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN (spec §1.7).</p>
 */
class TransportIdentificationsQuantificationsTest {

    @Test
    void identifications_table_round_trips_through_writer_and_reader(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildIdentificationsOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // materialiseTo returns an open handle; close via try-with.
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            assertEquals(a.identifications().size(), b.identifications().size(),
                "identification row count must round-trip");
            for (int i = 0; i < a.identifications().size(); i++) {
                Identification ia = a.identifications().get(i);
                Identification ib = b.identifications().get(i);
                assertEquals(ia.chemicalEntity(), ib.chemicalEntity());
                assertEquals(ia.confidenceScore(), ib.confidenceScore(), 1e-9);
                assertEquals(ia.evidenceChain(), ib.evidenceChain());
                assertEquals(ia.runName(), ib.runName());
                assertEquals(ia.spectrumIndex(), ib.spectrumIndex());
            }
            // Cross-cutting: the quantifications table must be empty for
            // an identifications-only fixture both before and after.
            assertTrue(a.quantifications().isEmpty());
            assertTrue(b.quantifications().isEmpty());
        }
    }

    @Test
    void quantifications_table_round_trips_through_writer_and_reader(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildQuantificationsOnly(tmp.resolve("src.tio"));
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
            assertEquals(a.quantifications().size(), b.quantifications().size(),
                "quantification row count must round-trip");
            for (int i = 0; i < a.quantifications().size(); i++) {
                Quantification qa = a.quantifications().get(i);
                Quantification qb = b.quantifications().get(i);
                assertEquals(qa.chemicalEntity(),      qb.chemicalEntity());
                assertEquals(qa.sampleRef(),           qb.sampleRef());
                assertEquals(qa.abundance(),           qb.abundance(), 1e-9);
                assertEquals(qa.normalizationMethod(), qb.normalizationMethod());
                assertEquals(qa.unit(),                qb.unit());
            }
            // Cross-cutting: the identifications table must be empty for
            // a quants-only fixture both before and after.
            assertTrue(a.identifications().isEmpty());
            assertTrue(b.identifications().isEmpty());
        }
    }

    /** Spec §5.4 step 6 says "zero or more" tables; an empty list
     *  must NOT emit a 0x16 packet on the wire. The reference-only
     *  fixture is a convenient stand-in for "no ids, no quants". */
    @Test
    void empty_identifications_emits_no_packet(@TempDir Path tmp) throws Exception {
        Path src = FixtureBuilder.buildReferenceOnly(tmp.resolve("src.tio"));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }
        TransportReader r = new TransportReader(out.toByteArray());
        var packets = r.recordsForTest();
        for (var rec : packets) {
            assertNotEquals(PacketType.IDENTIFICATIONS_TABLE,
                rec.header.packetType,
                "reference-only fixture must not emit IDENTIFICATIONS_TABLE");
            assertNotEquals(PacketType.QUANTIFICATIONS_TABLE,
                rec.header.packetType,
                "reference-only fixture must not emit QUANTIFICATIONS_TABLE");
        }
    }

    /** Sanity: with both ids and quants populated, the writer emits
     *  exactly one 0x16 followed by exactly one 0x17 (per §5.4 step 6,
     *  identifications-first ordering). */
    @Test
    void both_tables_emit_in_spec_order(@TempDir Path tmp) throws Exception {
        // Build a single dataset carrying BOTH ids and quants via the
        // 7-arg SpectralDataset.create overload.
        Path src = tmp.resolve("both.tio");
        List<Identification> ids = List.of(
            new Identification("run1", 0, "CompoundA", 0.5, List.of("e1")));
        List<Quantification> quants = List.of(
            new Quantification("CompoundA", "sample-1", 1.0,
                "intensity-sum", "counts"));
        try (SpectralDataset ds = SpectralDataset.create(
                src.toString(), "both", "",
                List.of(), ids, quants, List.of())) {
            // create-only fixture
        }

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }
        TransportReader r = new TransportReader(out.toByteArray());
        var packets = r.recordsForTest();
        int idIdx = -1;
        int qIdx  = -1;
        for (int i = 0; i < packets.size(); i++) {
            PacketType t = packets.get(i).header.packetType;
            if (t == PacketType.IDENTIFICATIONS_TABLE) {
                assertEquals(-1, idIdx, "duplicate IDENTIFICATIONS_TABLE");
                idIdx = i;
            } else if (t == PacketType.QUANTIFICATIONS_TABLE) {
                assertEquals(-1, qIdx, "duplicate QUANTIFICATIONS_TABLE");
                qIdx = i;
            }
        }
        assertTrue(idIdx > 0, "expected exactly one IDENTIFICATIONS_TABLE packet");
        assertTrue(qIdx  > 0, "expected exactly one QUANTIFICATIONS_TABLE packet");
        assertTrue(idIdx < qIdx,
            "per spec §5.4 step 6: IDENTIFICATIONS_TABLE precedes QUANTIFICATIONS_TABLE");
    }
}
